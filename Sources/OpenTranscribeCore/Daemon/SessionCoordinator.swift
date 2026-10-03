import Foundation

/// Wires detection, capture, transcription and output into one lifecycle.
///
/// Everything it talks to is a protocol from `Contracts`, so the whole flow can be driven by
/// fakes in tests without touching CoreAudio, CoreML or the real wiki folder.
public actor SessionCoordinator {
    public struct Config: Sendable {
        /// How long the notch keeps asking before the preroll buffer is dropped.
        public var promptTimeout: TimeInterval = 90
        /// Interval between live preview transcriptions.
        public var livePreviewInterval: TimeInterval = 20
        /// How long the "written" confirmation stays before falling back to idle.
        public var confirmationLinger: TimeInterval = 30
        /// Display name used for the microphone track.
        public var ownerName: String = "Sebastian"
        /// How far back the "important" button reaches.
        public var importantWindow: TimeInterval = 120
        /// How long finished recordings stay on disk. Zero deletes them right after a successful
        /// transcript. Kept non-zero by default because a transcript can come out wrong in ways
        /// nothing reports — a silent microphone, a dropped track — and without the audio there
        /// is no second chance.
        public var audioRetentionDays: Int = 7
        /// How often the state file is touched while recording, so the UI can tell a live
        /// recording from a dead daemon. Must stay well below the UI's staleness cutoff.
        public var heartbeatInterval: TimeInterval = 10

        public init() {}
    }

    private let paths: Paths
    private let config: Config
    private let detector: MeetingDetecting
    private let capture: AudioCapturing
    private let transcriber: Transcribing
    private let calendar: CalendarReading
    private let titles: TitleGenerating
    private let writer: TranscriptWriting
    private let learner: SpeakerLearning?
    private let publisher: WikiPublishing?
    private let corrector: TranscriptCorrecting?
    private let state: StateStore
    private let commands: CommandQueue
    private let now: @Sendable () -> Date

    /// Kept in memory so a speaker rename can rewrite the file without re-running the models.
    private var lastTranscript: Transcript?
    private var lastWrittenURL: URL?
    private var currentSession: SessionID?
    private var currentApp: MeetingApp?
    private var currentCalendar: CalendarContext?
    private var recordingStart: Date?
    private var liveOffset: TimeInterval = 0
    /// Consecutive live-preview windows in which the microphone delivered pure silence.
    private var silentMicWindows = 0
    /// Stretches the user flagged as important during the running recording.
    private var importantRanges: [ImportantRange] = []

    public init(
        paths: Paths,
        config: Config = Config(),
        detector: MeetingDetecting,
        capture: AudioCapturing,
        transcriber: Transcribing,
        calendar: CalendarReading,
        titles: TitleGenerating,
        writer: TranscriptWriting,
        state: StateStore,
        commands: CommandQueue,
        learner: SpeakerLearning? = nil,
        corrector: TranscriptCorrecting? = nil,
        publisher: WikiPublishing? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.learner = learner
        self.corrector = corrector
        self.publisher = publisher
        self.paths = paths
        self.config = config
        self.detector = detector
        self.capture = capture
        self.transcriber = transcriber
        self.calendar = calendar
        self.titles = titles
        self.writer = writer
        self.state = state
        self.commands = commands
        self.now = now
    }

    // MARK: - Lifecycle

    /// Runs until cancelled. Detection events and UI commands are handled concurrently.
    public func run() async throws {
        try paths.createDirectories()
        try await state.reset()
        await offerRecovery()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in await consumeDetection() }
            group.addTask { [self] in await consumeCommands() }
            group.addTask { [self] in await runLivePreview() }
            group.addTask { [self] in await runHeartbeat() }
        }
    }

    private func consumeDetection() async {
        for await event in detector.events() {
            do {
                switch event {
                case .meetingStarted(let app):
                    try await handleMeetingStarted(app)
                case .meetingEnded:
                    try await handleMeetingEnded()
                }
            } catch {
                try? await state.fail(code: "detection", message: "\(error)", recoverable: true)
            }
        }
    }

    private func consumeCommands() async {
        while !Task.isCancelled {
            for command in commands.drain() {
                do {
                    try await handle(command)
                } catch {
                    try? await state.fail(code: "command", message: "\(error)", recoverable: true)
                }
            }
            await expirePromptIfNeeded()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func runLivePreview() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.livePreviewInterval))
            guard await state.current.phase == .recording else { continue }
            await pumpLivePreview()
        }
    }

    /// Keeps the state file fresh while a recording runs.
    ///
    /// The notch hides a recording whose state is older than a minute, on purpose: a crashed
    /// daemon must not leave a phantom recording on screen. Without a heartbeat that same rule
    /// hides perfectly healthy long meetings, because nothing else writes the file between
    /// transitions — a live preview that produces no text writes nothing at all.
    private func runHeartbeat() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.heartbeatInterval))
            let phase = await state.current.phase
            guard phase == .recording || phase == .paused else { continue }
            try? await state.touch()
        }
    }

    // MARK: - Detection

    private func handleMeetingStarted(_ app: MeetingApp) async throws {
        // A lingering "written" confirmation — even one still asking for a speaker name — must
        // not swallow the next meeting. The new meeting wins.
        let phase = await state.current.phase
        guard phase == .idle || phase == .written else { return }

        // The buffer stays in memory only. Nothing reaches the disk before the user says yes.
        try await capture.startPrerollBuffer(app: app)
        let event = await calendar.currentEvent(at: now())
        currentApp = app
        currentCalendar = event

        let expiresAt = now().addingTimeInterval(config.promptTimeout)
        try await state.update {
            $0.phase = .detected
            $0.app = app
            $0.calendar = event
            $0.recentLines = []
            $0.lastWrittenFile = nil
            $0.speakers = []
            $0.session = nil
            $0.error = nil
            $0.pendingQuestion = .startRecording(app: app, calendar: event, expiresAt: expiresAt)
        }
    }

    private func handleMeetingEnded() async throws {
        switch await state.current.phase {
        case .detected:
            try await discardPrompt()
        case .recording, .paused:
            try await finalizeCurrentSession()
        default:
            break
        }
    }

    /// Drops the preroll once the notch prompt has been ignored long enough.
    private func expirePromptIfNeeded() async {
        let snapshot = await state.current
        guard snapshot.phase == .detected,
              case .startRecording(_, _, let expiresAt)? = snapshot.pendingQuestion,
              now() >= expiresAt
        else { return }
        try? await discardPrompt()
    }

    // MARK: - Commands

    private func handle(_ command: Command) async throws {
        switch command {
        case .start:
            try await startRecording()
        case .discard:
            try await discardPrompt()
        case .pause:
            guard await state.current.phase == .recording else { return }
            await capture.pause()
            try await state.transition(to: .paused)
        case .resume:
            guard await state.current.phase == .paused else { return }
            try await capture.resume()
            try await state.transition(to: .recording)
        case .stop:
            let phase = await state.current.phase
            guard phase == .recording || phase == .paused else { return }
            try await finalizeCurrentSession()
        case .assignSpeaker(_, let label, let name):
            try await renameSpeaker(label: label, to: name)
        case .finalize(let session):
            try await finalizeRecovered(session)
        case .markImportant:
            await markImportant()
        case .debugCapture(let seconds, let bundleID):
            try await runCaptureCheck(seconds: seconds, bundleID: bundleID)
        }
    }

    // MARK: - Recording retention

    /// Notes that a session has produced a transcript, and drops it if retention is off.
    private func markTranscribed(session: SessionID, file: URL) {
        guard config.audioRetentionDays > 0 else {
            try? FileManager.default.removeItem(at: paths.sessionDir(session))
            return
        }
        let marker = paths.sessionDir(session).appendingPathComponent("transcribed.txt")
        try? Data("\(file.path)\n".utf8).write(to: marker)
        purgeOldRecordings()
    }

    static func isTranscribed(paths: Paths, session: SessionID) -> Bool {
        FileManager.default.fileExists(
            atPath: paths.sessionDir(session).appendingPathComponent("transcribed.txt").path
        )
    }

    /// Removes recordings past the retention window. Anything not transcribed yet is kept
    /// regardless of age: unfinished work is exactly what must not disappear.
    private func purgeOldRecordings() {
        guard config.audioRetentionDays > 0 else { return }
        let cutoff = now().addingTimeInterval(-Double(config.audioRetentionDays) * 86_400)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: paths.recordingsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for dir in dirs where dir.hasDirectoryPath {
            let session = SessionID(raw: dir.lastPathComponent)
            guard Self.isTranscribed(paths: paths, session: session) else { continue }
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: - Importance markers

    /// Flags the stretch that just happened. Ranges are relative to the start of the recording,
    /// clamped at zero, and merged when they overlap so repeated presses do not pile up.
    private func markImportant() async {
        guard let startedAt = recordingStart else { return }
        let phase = await state.current.phase
        guard phase == .recording || phase == .paused else { return }

        let elapsed = now().timeIntervalSince(startedAt)
        let range = ImportantRange(start: max(0, elapsed - config.importantWindow), end: elapsed)
        importantRanges = Self.merge(importantRanges + [range])
    }

    static func merge(_ ranges: [ImportantRange]) -> [ImportantRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [ImportantRange] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = ImportantRange(
                    start: last.start, end: max(last.end, range.end)
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: - Capture diagnostics

    /// Runs both real capture sources directly (not through the `AudioCapturing` preroll
    /// abstraction, which only hands back a flat sample array) for `seconds` and measures what
    /// actually comes back, per callback. This exists because the command line has no
    /// microphone or audio-capture permission — only the installed app does — so it is the only
    /// way to measure real capture behavior without sitting through a whole meeting.
    ///
    /// Counting callbacks separately from sample content is what tells apart the two failure
    /// modes that otherwise look identical from a peak reading alone: a tap that never fires at
    /// all (callbacks == 0, a setup/wiring problem) versus one that fires normally but every
    /// buffer it delivers is silent (callbacks > 0, peak == 0 — e.g. voice processing silencing
    /// the mic, or a tap bound to the wrong process).
    private func runCaptureCheck(seconds: Int, bundleID: String?) async throws {
        guard await state.current.phase == .idle else {
            try await appendCaptureCheckResult("skipped: daemon is busy (\(await state.current.phase.rawValue))")
            return
        }
        let app = try resolveDebugApp(bundleID: bundleID)

        let micCounter = CaptureCheckCounter()
        let remoteCounter = CaptureCheckCounter()
        let mic = MicCapture()
        let remote = ProcessTapCapture(app: app)

        do {
            try mic.start { samples in await micCounter.ingest(samples) }
        } catch {
            try await appendCaptureCheckResult("mic start failed: \(error)")
            return
        }
        do {
            try remote.start { samples in await remoteCounter.ingest(samples) }
        } catch {
            mic.stop()
            try await appendCaptureCheckResult("remote start failed: \(error)")
            return
        }

        try? await Task.sleep(for: .seconds(seconds))
        mic.stop()
        remote.stop()

        // Second opinion on the microphone through a completely different AVFoundation route,
        // so a silent mic can be pinned on either this machine or our sample plumbing.
        let probe = await MicFileProbe.record(seconds: min(seconds, 5))

        let summary = "bundleID=\(app.bundleID) seconds=\(seconds) "
            + "mic[\(await micCounter.summary())] remote[\(await remoteCounter.summary())] "
            + String(format: "micFileProbe[peak=%.5f frames=%d %@] ", probe.peak, probe.frames, probe.note)
            + "micDevice[\(mic.activeDeviceName)]"
        try await appendCaptureCheckResult(summary)
    }

    private func resolveDebugApp(bundleID: String?) throws -> MeetingApp {
        if let bundleID {
            let snapshots = (try? CoreAudioProcessSource().snapshot()) ?? []
            guard let match = snapshots.first(where: {
                $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".")
            }) else {
                throw SessionCoordinatorError.processNotFound(bundleID)
            }
            return MeetingApp(bundleID: bundleID, name: bundleID, pid: match.pid)
        }
        guard let app = currentApp else { throw SessionCoordinatorError.noAppToCheck }
        return app
    }

    private func appendCaptureCheckResult(_ summary: String) async throws {
        let line = "\(ISO8601DateFormatter().string(from: now())) capturecheck \(summary)\n"
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        let logURL = paths.logsDir.appendingPathComponent("capture-check.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
        // Surfaced through state.json without touching `phase`, so a debug check never blocks
        // real meeting detection that might be waiting on phase == .idle elsewhere.
        try await state.update {
            $0.error = DaemonError(code: "capturecheck", message: summary, recoverable: true)
        }
    }

    private func startRecording() async throws {
        guard await state.current.phase == .detected, let app = currentApp else { return }
        let startedAt = now()
        let session = SessionID(date: startedAt)
        try await capture.commitToDisk(session: session)
        // Written next to the audio so a crash before `finalizeCurrentSession` still leaves
        // behind which app and when — crash recovery has nothing else to go on.
        try? RecordingMeta(session: session, startedAt: startedAt, appName: app.name, duration: 0)
            .save(paths: paths)

        currentSession = session
        recordingStart = startedAt
        liveOffset = 0

        try await state.update {
            $0.phase = .recording
            $0.session = session
            $0.startedAt = startedAt
            $0.pendingQuestion = nil
            $0.app = app
        }
    }

    private func discardPrompt() async throws {
        await capture.discardPreroll()
        currentApp = nil
        currentCalendar = nil
        try await state.update {
            $0.phase = .idle
            $0.pendingQuestion = nil
            $0.app = nil
            $0.calendar = nil
        }
    }

    // MARK: - Live preview

    private func pumpLivePreview() async {
        let window = config.livePreviewInterval
        var lines: [LiveLine] = []
        for track in [Track.mic, Track.remote] {
            let samples = await capture.recentSamples(track: track, seconds: window)
            if track == .mic { await watchForSilentMic(samples) }
            guard !samples.isEmpty else { continue }
            if let produced = try? await transcriber.transcribeLiveChunk(
                samples, track: track, offset: liveOffset
            ) {
                lines.append(contentsOf: produced)
            }
        }
        liveOffset += window
        guard !lines.isEmpty else { return }
        lines.sort { $0.at < $1.at }
        try? await state.appendLiveLines(lines)
        appendLiveJSONL(lines)
    }

    /// A microphone that records bit-exact silence looks exactly like a working one until the
    /// transcript comes back empty — which already cost two real meetings. Two silent windows in
    /// a row raise a visible warning while the meeting is still running and can be saved.
    private func watchForSilentMic(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak == 0 else {
            silentMicWindows = 0
            return
        }
        silentMicWindows += 1
        guard silentMicWindows == 2 else { return }
        try? await state.warn(
            code: "silentMic",
            message: "Das Mikrofon nimmt nur Stille auf. Prüfe das Eingabegerät, "
                + "bei zugeklapptem MacBook ist das eingebaute Mikrofon tot."
        )
    }

    private func appendLiveJSONL(_ lines: [LiveLine]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = lines
            .compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        guard !payload.isEmpty else { return }
        let data = Data((payload + "\n").utf8)

        if let handle = try? FileHandle(forWritingTo: paths.liveTranscript) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: paths.liveTranscript)
        }
    }

    // MARK: - Finalisation

    private func finalizeCurrentSession() async throws {
        guard let session = currentSession, let startedAt = recordingStart else { return }
        try await state.transition(to: .finalizing)
        let tracks = try await capture.stop()
        if var meta = RecordingMeta.load(paths: paths, session: session) {
            meta.duration = now().timeIntervalSince(startedAt)
            try? meta.save(paths: paths)
        }
        try await produceTranscript(
            session: session,
            startedAt: startedAt,
            tracks: tracks,
            app: currentApp?.name ?? "Meeting",
            calendar: currentCalendar
        )
    }

    private func finalizeRecovered(_ session: SessionID) async throws {
        let meta = RecordingMeta.load(paths: paths, session: session)
        var tracks: [Track: URL] = [:]
        for track in [Track.mic, Track.remote] {
            let url = paths.trackFile(session, track)
            if FileManager.default.fileExists(atPath: url.path) { tracks[track] = url }
        }
        guard !tracks.isEmpty else {
            try await state.update { $0.pendingQuestion = nil; $0.phase = .idle }
            return
        }
        try await state.transition(to: .finalizing)
        try await produceTranscript(
            session: session,
            startedAt: meta?.startedAt ?? Date(),
            tracks: tracks,
            app: meta?.appName ?? "Meeting",
            calendar: nil
        )
    }

    private func produceTranscript(
        session: SessionID,
        startedAt: Date,
        tracks: [Track: URL],
        app: String,
        calendar: CalendarContext?
    ) async throws {
        do {
            try await transcriber.prepare()
            var transcript = try await transcriber.finalPass(
                tracks: tracks,
                context: FinalPassContext(
                    session: session,
                    recordedAt: startedAt,
                    appName: app,
                    calendar: calendar,
                    ownerName: config.ownerName
                )
            )
            // A failing corrector must never abort the write — the uncorrected transcript
            // is always better than no transcript.
            if let corrector {
                transcript = await corrector.correct(transcript)
            }
            transcript.importantRanges = importantRanges
            let slug = await titles.slug(for: transcript)
            let url = try writer.write(transcript, slug: slug)

            lastTranscript = transcript
            lastWrittenURL = url

            markTranscribed(session: session, file: url)
            importantRanges = []

            // The ingest that turns this into wiki pages and Linear issues runs elsewhere and
            // pulls from git, so an unpushed file is a file nothing will ever process.
            if let publisher, let problem = await publisher.publish(url) {
                try? await state.warn(code: "notPublished", message: problem)
            }

            let finalTranscript = transcript
            try await state.update {
                $0.phase = .written
                $0.lastWrittenFile = url.path
                $0.recentLines = []
                $0.session = session
                $0.speakers = finalTranscript.speakers
                $0.pendingQuestion = Self.namingQuestion(
                    for: finalTranscript,
                    session: session,
                    calendar: calendar
                )
            }
            scheduleIdleAfterConfirmation(session: session)
        } catch {
            // Recording stays on disk so nothing is lost and the user can retry.
            try await state.fail(
                code: "transcription",
                message: "Transkription fehlgeschlagen: \(error). Aufnahme bleibt unter \(paths.sessionDir(session).path).",
                recoverable: true
            )
        }
        currentSession = nil
        currentApp = nil
        currentCalendar = nil
        recordingStart = nil
    }

    /// Asks about the first unresolved cluster only. One question at a time keeps the notch calm.
    /// The voice-profile suggestion, if any, leads the candidates; calendar attendees follow.
    static func namingQuestion(
        for transcript: Transcript,
        session: SessionID,
        calendar: CalendarContext?
    ) -> PendingQuestion? {
        guard let label = transcript.speakers.first(where: { $0.hasPrefix("Speaker ") }) else {
            return nil
        }
        let taken = Set(transcript.speakers)
        let suggestion = transcript.speakerSuggestions[label].flatMap { taken.contains($0) ? nil : $0 }
        var candidates = suggestion.map { [$0] } ?? []
        for attendee in calendar?.attendees ?? [] where !taken.contains(attendee) && !candidates.contains(attendee) {
            candidates.append(attendee)
        }
        return .nameSpeaker(
            session: session,
            label: label,
            candidates: candidates,
            sample: Self.sample(for: label, in: transcript.segments),
            suggestion: suggestion
        )
    }

    /// Something the speaker said that is long enough to place them: the first utterance of at
    /// least a few words, or failing that the first one at all. Cut to fit one notch line.
    static func sample(for label: String, in segments: [TranscriptSegment], limit: Int = 140) -> String {
        let own = segments.lazy.filter { $0.speaker == label }.map(\.text)
        let text = own.first { $0.count >= 30 } ?? own.first { _ in true } ?? ""
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Falls back to idle once the confirmation has lingered and no question is open. Keeps
    /// checking for as long as this session stays in `.written`: the naming question can be
    /// answered long after the first linger, and a one-shot timer that gave up at that point
    /// left the daemon in `.written` for good — refusing every meeting that came after.
    private func scheduleIdleAfterConfirmation(session: SessionID) {
        Task { [config, state] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(config.confirmationLinger))
                let snapshot = await state.current
                guard snapshot.phase == .written, snapshot.session == session else { return }
                guard snapshot.pendingQuestion == nil else { continue }
                _ = try? await state.update {
                    $0.phase = .idle
                    $0.lastWrittenFile = nil
                    $0.speakers = []
                    $0.session = nil
                }
                return
            }
        }
    }

    // MARK: - Speaker renaming

    private func renameSpeaker(label: String, to name: String) async throws {
        guard var transcript = lastTranscript, let url = lastWrittenURL else { return }
        // Learn the voice first: the label disappears from the transcript in the next step.
        await learner?.learn(label: label, as: name)
        for index in transcript.segments.indices where transcript.segments[index].speaker == label {
            transcript.segments[index].speaker = name
        }
        _ = try writer.rewrite(transcript, at: url)
        lastTranscript = transcript

        // The first version was already pushed, so the renamed one has to follow it. Otherwise
        // the ingest on the VPS processes a transcript that still says "Speaker A".
        if let publisher, let problem = await publisher.publish(url) {
            try? await state.warn(code: "notPublished", message: problem)
        }

        let updated = transcript
        let session = updated.session
        let calendar = currentCalendar
        try await state.update {
            $0.speakers = updated.speakers
            $0.pendingQuestion = Self.namingQuestion(
                for: updated,
                session: session,
                calendar: calendar
            )
        }
    }

    // MARK: - Crash recovery

    /// A recording left behind by a crashed run is offered for late transcription.
    private func offerRecovery() async {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: paths.recordingsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let pending = dirs.filter {
            $0.hasDirectoryPath && !Self.isTranscribed(paths: paths, session: SessionID(raw: $0.lastPathComponent))
        }
        guard let newest = pending.sorted(by: { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }).first else { return }

        let session = SessionID(raw: newest.lastPathComponent)
        let meta = RecordingMeta.load(paths: paths, session: session)
        let recordedAt = meta?.startedAt
            ?? (try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
        let duration = meta?.duration ?? 0

        _ = try? await state.update {
            $0.pendingQuestion = .recoverSession(
                session: session,
                recordedAt: recordedAt,
                duration: duration
            )
        }
    }
}

/// Tallies raw capture callbacks for `debugCapture`: how many fired, how many samples they
/// carried in total, and the peak/RMS of their content — enough to tell a dead tap from a live
/// one delivering silence.
private actor CaptureCheckCounter {
    private var callbackCount = 0
    private var totalSamples = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0

    func ingest(_ samples: [Float]) {
        callbackCount += 1
        totalSamples += samples.count
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += Double(sample) * Double(sample)
        }
    }

    func summary() -> String {
        let rms = totalSamples > 0 ? Float((sumSquares / Double(totalSamples)).squareRoot()) : 0
        let peak16 = Int((peak * 32767).rounded())
        return String(
            format: "callbacks=%d samples=%d peak=%.5f (%d/32767) rms=%.5f",
            callbackCount, totalSamples, peak, peak16, rms)
    }
}

/// Errors specific to the `debugCapture` diagnostic path.
public enum SessionCoordinatorError: Error, Sendable, Equatable {
    case processNotFound(String)
    case noAppToCheck
}

/// Written next to the audio so a crashed session can still be attributed afterwards.
public struct RecordingMeta: Codable, Sendable {
    public let session: SessionID
    public let startedAt: Date
    public let appName: String
    public var duration: TimeInterval

    public init(session: SessionID, startedAt: Date, appName: String, duration: TimeInterval) {
        self.session = session
        self.startedAt = startedAt
        self.appName = appName
        self.duration = duration
    }

    public func save(paths: Paths) throws {
        try FileManager.default.createDirectory(
            at: paths.sessionDir(session), withIntermediateDirectories: true
        )
        try OTJSON.encoder.encode(self).writeAtomically(to: paths.metaFile(session))
    }

    public static func load(paths: Paths, session: SessionID) -> RecordingMeta? {
        guard let data = try? Data(contentsOf: paths.metaFile(session)) else { return nil }
        return try? OTJSON.decoder.decode(RecordingMeta.self, from: data)
    }
}
