import Foundation
import Testing

@testable import OpenTranscribeCore

// MARK: - Fakes

final class DetectorFake: MeetingDetecting, @unchecked Sendable {
    private let stream: AsyncStream<DetectionEvent>
    let continuation: AsyncStream<DetectionEvent>.Continuation

    init() {
        var cont: AsyncStream<DetectionEvent>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    func events() -> AsyncStream<DetectionEvent> { stream }
}

actor CaptureFake: AudioCapturing {
    private(set) var prerollStarted = false
    private(set) var committed: SessionID?
    private(set) var discarded = false
    private(set) var stopped = false
    private(set) var paused = false
    var tracks: [Track: URL] = [:]

    func startPrerollBuffer(app: MeetingApp) async throws { prerollStarted = true }
    func commitToDisk(session: SessionID) async throws { committed = session }
    func discardPreroll() async { discarded = true }
    func pause() async { paused = true }
    func resume() async throws { paused = false }
    func stop() async throws -> [Track: URL] {
        stopped = true
        return tracks
    }
    func recentSamples(track: Track, seconds: TimeInterval) async -> [Float] { [] }
}

actor TranscriberFake: Transcribing {
    var transcript: Transcript?
    var shouldThrow = false
    private(set) var prepared = false

    init(transcript: Transcript? = nil) { self.transcript = transcript }

    func prepare() async throws { prepared = true }

    func transcribeLiveChunk(_ samples: [Float], track: Track, offset: TimeInterval) async throws -> [LiveLine] { [] }

    func finalPass(tracks: [Track: URL], context: FinalPassContext) async throws -> Transcript {
        if shouldThrow { throw NSError(domain: "test", code: 1) }
        if let transcript { return transcript }
        return Transcript(
            session: context.session,
            recordedAt: context.recordedAt,
            duration: 60,
            appName: context.appName,
            calendarTitle: context.calendar?.title,
            segments: [
                TranscriptSegment(start: 0, end: 2, track: .mic, speaker: context.ownerName, text: "Moin."),
                TranscriptSegment(start: 3, end: 5, track: .remote, speaker: "Speaker A", text: "Servus."),
            ]
        )
    }
}

struct CalendarFake: CalendarReading {
    var event: CalendarContext?
    func currentEvent(at date: Date) async -> CalendarContext? { event }
}

struct TitlesFake: TitleGenerating {
    func slug(for transcript: Transcript) async -> String { "test-meeting" }
}

final class WriterSpy: TranscriptWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _written: [(Transcript, String)] = []
    private var _rewritten: [Transcript] = []
    let target: URL

    init(target: URL) { self.target = target }

    var written: [(Transcript, String)] { lock.withLock { _written } }
    var rewritten: [Transcript] { lock.withLock { _rewritten } }

    func write(_ transcript: Transcript, slug: String) throws -> URL {
        lock.withLock { _written.append((transcript, slug)) }
        let url = target.appendingPathComponent("\(slug).md")
        try Data("written".utf8).write(to: url)
        return url
    }

    func rewrite(_ transcript: Transcript, at url: URL) throws -> URL {
        lock.withLock { _rewritten.append(transcript) }
        return url
    }
}

// MARK: - Harness

@MainActor
private func makeHarness(heartbeat: TimeInterval = 3600) throws -> (
    coordinator: SessionCoordinator,
    detector: DetectorFake,
    capture: CaptureFake,
    transcriber: TranscriberFake,
    writer: WriterSpy,
    state: StateStore,
    commands: CommandQueue,
    paths: Paths,
    config: SessionCoordinator.Config
) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ot-tests-\(UUID().uuidString)", isDirectory: true)
    let wiki = root.appendingPathComponent("wiki", isDirectory: true)
    try FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
    let paths = Paths(root: root, wikiRaw: wiki)
    try paths.createDirectories()

    let detector = DetectorFake()
    let capture = CaptureFake()
    let transcriber = TranscriberFake()
    let writer = WriterSpy(target: wiki)
    let state = StateStore(paths: paths)
    let commands = CommandQueue(paths: paths)

    var config = SessionCoordinator.Config()
    config.promptTimeout = 1
    config.livePreviewInterval = 3600
    config.confirmationLinger = 3600
    config.heartbeatInterval = heartbeat

    let coordinator = SessionCoordinator(
        paths: paths,
        config: config,
        detector: detector,
        capture: capture,
        transcriber: transcriber,
        calendar: CalendarFake(event: CalendarContext(
            title: "Mühlenbäcker Weekly",
            attendees: ["Alex Meyer"],
            startsAt: Date(),
            endsAt: Date().addingTimeInterval(3600)
        )),
        titles: TitlesFake(),
        writer: writer,
        state: state,
        commands: commands
    )
    return (coordinator, detector, capture, transcriber, writer, state, commands, paths, config)
}

/// Polls until the predicate holds or the deadline passes. The coordinator is event driven,
/// so tests wait for a condition instead of guessing a sleep duration.
private func waitFor(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await condition()
}

private let testApp = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom", pid: 4242)

// MARK: - Tests

@Test @MainActor func detectionAsksBeforeTouchingTheDisk() async throws {
    let h = try makeHarness()
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))

    #expect(await waitFor { await h.state.current.phase == .detected })
    let snapshot = await h.state.current
    #expect(snapshot.app?.bundleID == "us.zoom.xos")
    #expect(snapshot.calendar?.title == "Mühlenbäcker Weekly")
    if case .startRecording? = snapshot.pendingQuestion {} else {
        Issue.record("expected a start question, got \(String(describing: snapshot.pendingQuestion))")
    }
    #expect(await h.capture.prerollStarted)
    #expect(await h.capture.committed == nil)
}

@Test @MainActor func startCommandPromotesThePrerollToARecording() async throws {
    let h = try makeHarness()
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })

    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })
    #expect(await h.capture.committed != nil)
    #expect(await h.state.current.pendingQuestion == nil)
}

@Test @MainActor func ignoringThePromptDiscardsTheBuffer() async throws {
    let h = try makeHarness()
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })

    // promptTimeout is 1s in the harness.
    #expect(await waitFor { await h.state.current.phase == .idle })
    #expect(await h.capture.discarded)
    #expect(await h.capture.committed == nil)
    #expect(h.writer.written.isEmpty)
}

@Test @MainActor func meetingEndWritesTheTranscriptAndAsksForTheSpeakerName() async throws {
    let h = try makeHarness()
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })

    h.detector.continuation.yield(.meetingEnded(testApp))
    #expect(await waitFor { await h.state.current.phase == .written })

    #expect(await h.capture.stopped)
    #expect(h.writer.written.count == 1)
    #expect(h.writer.written.first?.1 == "test-meeting")
    #expect(await h.state.current.lastWrittenFile?.hasSuffix("test-meeting.md") == true)

    guard case .nameSpeaker(_, let label, let candidates, let sample, let suggestion)? = await h.state.current.pendingQuestion else {
        Issue.record("expected a naming question")
        return
    }
    #expect(label == "Speaker A")
    #expect(candidates == ["Alex Meyer"])
    #expect(sample == "Servus.")
    #expect(suggestion == nil)
    #expect(await h.state.current.speakers == ["Sebastian", "Speaker A"])
}

@Test @MainActor func assigningANameRewritesTheFile() async throws {
    let h = try makeHarness()
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })
    try h.commands.send(.stop)
    #expect(await waitFor { await h.state.current.phase == .written })

    guard case .nameSpeaker(let session, _, _, _, _)? = await h.state.current.pendingQuestion else {
        Issue.record("expected a naming question")
        return
    }
    try h.commands.send(.assignSpeaker(session: session, label: "Speaker A", name: "Alex"))

    #expect(await waitFor { h.writer.rewritten.count == 1 })
    let rewritten = try #require(h.writer.rewritten.first)
    #expect(rewritten.speakers.contains("Alex"))
    #expect(!rewritten.speakers.contains("Speaker A"))
    #expect(await h.state.current.pendingQuestion == nil)
}

@Test @MainActor func aWronglyRecognisedNameCanBeCorrectedAfterwards() async throws {
    // A profile match is a guess, not a fact: the user has to be able to overrule it in the
    // notch, exactly like an unresolved "Speaker X".
    let h = try makeHarness()
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })
    try h.commands.send(.stop)
    #expect(await waitFor { await h.state.current.phase == .written })

    guard case .nameSpeaker(let session, _, _, _, _)? = await h.state.current.pendingQuestion else {
        Issue.record("expected a naming question")
        return
    }
    try h.commands.send(.assignSpeaker(session: session, label: "Speaker A", name: "Alex"))
    #expect(await waitFor { h.writer.rewritten.count == 1 })
    #expect(await h.state.current.speakers == ["Sebastian", "Alex"])

    try h.commands.send(.assignSpeaker(session: session, label: "Alex", name: "Kim"))
    #expect(await waitFor { h.writer.rewritten.count == 2 })
    let corrected = try #require(h.writer.rewritten.last)
    #expect(corrected.speakers == ["Sebastian", "Kim"])
    #expect(await h.state.current.speakers == ["Sebastian", "Kim"])
}

@Test func namingSampleQuotesSomethingSubstantialTheSpeakerSaid() {
    let segments = [
        TranscriptSegment(start: 0, end: 1, track: .remote, speaker: "Speaker A", text: "Hm."),
        TranscriptSegment(start: 2, end: 6, track: .remote, speaker: "Speaker A", text: "Ich habe mit Personio gesprochen, die Schnittstelle gibt es nicht."),
        TranscriptSegment(start: 7, end: 8, track: .remote, speaker: "Speaker B", text: "Ja, okay, verstehe."),
    ]
    #expect(SessionCoordinator.sample(for: "Speaker A", in: segments) == "Ich habe mit Personio gesprochen, die Schnittstelle gibt es nicht.")
    // Nothing substantial: fall back to whatever there is rather than an empty question.
    #expect(SessionCoordinator.sample(for: "Speaker B", in: segments) == "Ja, okay, verstehe.")
    #expect(SessionCoordinator.sample(for: "Speaker C", in: segments) == "")
}

@Test func namingSampleIsTruncatedForTheNotch() {
    let long = String(repeating: "wort ", count: 60)
    let segments = [TranscriptSegment(start: 0, end: 1, track: .remote, speaker: "Speaker A", text: long)]
    let sample = SessionCoordinator.sample(for: "Speaker A", in: segments)
    #expect(sample.count <= 141)
    #expect(sample.hasSuffix("…"))
}

@Test @MainActor func failedTranscriptionKeepsTheAudioAndSurfacesTheError() async throws {
    let h = try makeHarness()
    await h.transcriber.setShouldThrow(true)
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })

    let session = try #require(await h.state.current.session)
    let sessionDir = h.paths.sessionDir(session)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: h.paths.trackFile(session, .mic))

    try h.commands.send(.stop)
    #expect(await waitFor { await h.state.current.phase == .error })
    #expect(await h.state.current.error?.code == "transcription")
    #expect(FileManager.default.fileExists(atPath: h.paths.trackFile(session, .mic).path))
    #expect(h.writer.written.isEmpty)
}

@Test @MainActor func pauseAndResumeToggleThePhase() async throws {
    let h = try makeHarness()
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })

    try h.commands.send(.pause)
    #expect(await waitFor { await h.state.current.phase == .paused })
    #expect(await h.capture.paused)

    try h.commands.send(.resume)
    #expect(await waitFor { await h.state.current.phase == .recording })
    #expect(await h.capture.paused == false)
}

@Test @MainActor func recordingMetaIsWrittenOnStartAndDurationUpdatedOnStop() async throws {
    let h = try makeHarness()
    await h.transcriber.setShouldThrow(true) // keeps the session (and its meta.json) on disk
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })

    let session = try #require(await h.state.current.session)
    let metaAfterStart = RecordingMeta.load(paths: h.paths, session: session)
    #expect(metaAfterStart?.appName == "Zoom")
    #expect(metaAfterStart?.duration == 0)

    try await Task.sleep(for: .milliseconds(50))
    try h.commands.send(.stop)
    #expect(await waitFor { await h.state.current.phase == .error })

    let metaAfterStop = RecordingMeta.load(paths: h.paths, session: session)
    #expect((metaAfterStop?.duration ?? 0) > 0)
}

extension TranscriberFake {
    func setShouldThrow(_ value: Bool) { shouldThrow = value }
}

// Repeated presses of the important button must not pile up overlapping ranges.

@Test func overlappingImportantRangesAreMerged() {
    let merged = SessionCoordinator.merge([
        ImportantRange(start: 100, end: 220),
        ImportantRange(start: 200, end: 320),
        ImportantRange(start: 600, end: 720),
    ])
    #expect(merged == [ImportantRange(start: 100, end: 320), ImportantRange(start: 600, end: 720)])
}

@Test func disjointImportantRangesStaySeparate() {
    let merged = SessionCoordinator.merge([
        ImportantRange(start: 600, end: 720),
        ImportantRange(start: 0, end: 120),
    ])
    #expect(merged == [ImportantRange(start: 0, end: 120), ImportantRange(start: 600, end: 720)])
}

// A long meeting must keep the state file fresh, otherwise the notch treats it as a dead daemon
// and hides a recording that is running perfectly well.

@Test @MainActor func recordingKeepsTheStateFileFresh() async throws {
    let h = try makeHarness(heartbeat: 0.2)
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })

    // The file on disk is what the UI reads, and its timestamps carry whole-second resolution,
    // so this waits for the persisted stamp itself to move rather than the in-memory one.
    let firstStamp = StateStore.loadPersisted(paths: h.paths).updatedAt
    let paths = h.paths
    #expect(await waitFor(timeout: 6) {
        StateStore.loadPersisted(paths: paths).updatedAt > firstStamp
    })
    #expect(StateStore.loadPersisted(paths: paths).phase == .recording)
}

// Audio used to be deleted the moment a transcript was written. That cost a real 32 minute
// meeting when the transcript turned out to be missing a whole speaker.

@Test @MainActor func audioSurvivesTheTranscriptAndTheRecoveryQuestionDoesNotComeBack() async throws {
    let h = try makeHarness()
    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })

    let session = try #require(await h.state.current.session)
    let dir = h.paths.sessionDir(session)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: h.paths.trackFile(session, .mic))

    try h.commands.send(.stop)
    #expect(await waitFor { await h.state.current.phase == .written })

    // Audio is still there, and marked as already transcribed.
    #expect(FileManager.default.fileExists(atPath: h.paths.trackFile(session, .mic).path))
    #expect(SessionCoordinator.isTranscribed(paths: h.paths, session: session))
}

@Test @MainActor func anUntranscribedRecordingIsStillOfferedForRecovery() async throws {
    let h = try makeHarness()
    let session = SessionID(raw: "2026-08-19T09-00-00")
    let dir = h.paths.sessionDir(session)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: h.paths.trackFile(session, .mic))

    let task = Task { try await h.coordinator.run() }
    defer { task.cancel() }

    #expect(await waitFor {
        if case .recoverSession? = await h.state.current.pendingQuestion { return true }
        return false
    })
}

// The rename rewrites a file that was already pushed, so it has to be published again — the
// ingest runs from git, and would otherwise process the version with "Speaker A" in it.

@Test @MainActor func renamingASpeakerPublishesTheRewrittenFile() async throws {
    final class PublisherSpy: WikiPublishing, @unchecked Sendable {
        private let lock = NSLock()
        private var _published: [URL] = []
        var published: [URL] { lock.withLock { _published } }
        func publish(_ file: URL) async -> String? {
            lock.withLock { _published.append(file) }
            return nil
        }
    }

    let h = try makeHarness()
    let publisher = PublisherSpy()
    let coordinator = SessionCoordinator(
        paths: h.paths, config: h.config, detector: h.detector, capture: h.capture,
        transcriber: h.transcriber, calendar: CalendarFake(event: nil), titles: TitlesFake(),
        writer: h.writer, state: h.state, commands: h.commands, publisher: publisher
    )
    let task = Task { try await coordinator.run() }
    defer { task.cancel() }

    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })
    try h.commands.send(.stop)
    #expect(await waitFor { await h.state.current.phase == .written })
    #expect(await waitFor { publisher.published.count == 1 })

    guard case .nameSpeaker(let session, let label, _, _, _)? = await h.state.current.pendingQuestion else {
        Issue.record("expected a naming question")
        return
    }
    try h.commands.send(.assignSpeaker(session: session, label: label, name: "Jonas"))
    #expect(await waitFor { publisher.published.count == 2 })
    #expect(publisher.published[0] == publisher.published[1])
}

// MARK: - Leaving the "written" phase

/// Drives a full session to `.written` on a coordinator built from `config`.
@MainActor
private func runToWritten(
    _ h: (coordinator: SessionCoordinator, detector: DetectorFake, capture: CaptureFake,
          transcriber: TranscriberFake, writer: WriterSpy, state: StateStore,
          commands: CommandQueue, paths: Paths, config: SessionCoordinator.Config),
    config: SessionCoordinator.Config
) async throws -> Task<Void, Error> {
    let coordinator = SessionCoordinator(
        paths: h.paths, config: config, detector: h.detector, capture: h.capture,
        transcriber: h.transcriber, calendar: CalendarFake(event: nil), titles: TitlesFake(),
        writer: h.writer, state: h.state, commands: h.commands
    )
    let task = Task { try await coordinator.run() }
    h.detector.continuation.yield(.meetingStarted(testApp))
    #expect(await waitFor { await h.state.current.phase == .detected })
    try h.commands.send(.start)
    #expect(await waitFor { await h.state.current.phase == .recording })
    try h.commands.send(.stop)
    #expect(await waitFor { await h.state.current.phase == .written })
    return task
}

// The idle fallback used to be a one-shot timer armed when the transcript was written. If the
// naming question was still open when it fired, it gave up for good — and answering the
// question afterwards left the daemon in `.written` forever, refusing every new meeting.

@Test @MainActor func answeringTheNamingQuestionAfterTheLingerStillReturnsToIdle() async throws {
    let h = try makeHarness()
    var config = h.config
    config.confirmationLinger = 0.2
    let task = try await runToWritten(h, config: config)
    defer { task.cancel() }

    // Let the linger pass while the question is still unanswered.
    try await Task.sleep(for: .milliseconds(600))
    #expect(await h.state.current.phase == .written)

    guard case .nameSpeaker(let session, let label, _, _, _)? = await h.state.current.pendingQuestion else {
        Issue.record("expected a naming question")
        return
    }
    try h.commands.send(.assignSpeaker(session: session, label: label, name: "Jonas"))

    #expect(await waitFor { await h.state.current.phase == .idle })
    let snapshot = await h.state.current
    #expect(snapshot.lastWrittenFile == nil)
    #expect(snapshot.session == nil)
}

// An unanswered naming question must not block the next meeting. The new meeting wins.

@Test @MainActor func aNewMeetingPreemptsAnUnansweredNamingQuestion() async throws {
    let h = try makeHarness()
    let task = try await runToWritten(h, config: h.config)
    defer { task.cancel() }

    guard case .nameSpeaker? = await h.state.current.pendingQuestion else {
        Issue.record("expected a naming question")
        return
    }

    h.detector.continuation.yield(.meetingStarted(testApp))

    #expect(await waitFor { await h.state.current.phase == .detected })
    let snapshot = await h.state.current
    if case .startRecording? = snapshot.pendingQuestion {} else {
        Issue.record("expected a start question, got \(String(describing: snapshot.pendingQuestion))")
    }
    #expect(snapshot.lastWrittenFile == nil)
}

@Test func aVoiceMatchLeadsTheCandidatesButIsOnlyASuggestion() {
    let transcript = Transcript(
        session: SessionID(raw: "s"), recordedAt: Date(), duration: 10, appName: "Zoom", calendarTitle: nil,
        segments: [
            TranscriptSegment(start: 0, end: 1, track: .mic, speaker: "Sebastian", text: "Moin."),
            TranscriptSegment(start: 2, end: 3, track: .remote, speaker: "Speaker A", text: "Servus, alles klar bei euch?"),
        ],
        speakerSuggestions: ["Speaker A": "Alex"]
    )
    let calendar = CalendarContext(title: "Sync", attendees: ["Kim", "Alex"], startsAt: Date(), endsAt: Date())

    guard case .nameSpeaker(_, let label, let candidates, _, let suggestion)? =
        SessionCoordinator.namingQuestion(for: transcript, session: transcript.session, calendar: calendar)
    else {
        Issue.record("expected a naming question")
        return
    }
    // The transcript itself still says "Speaker A": the match is offered, not applied.
    #expect(label == "Speaker A")
    #expect(suggestion == "Alex")
    #expect(candidates == ["Alex", "Kim"])
}

@Test func aSuggestionAlreadyUsedForAnotherSpeakerIsDropped() {
    let transcript = Transcript(
        session: SessionID(raw: "s"), recordedAt: Date(), duration: 10, appName: "Zoom", calendarTitle: nil,
        segments: [
            TranscriptSegment(start: 0, end: 1, track: .remote, speaker: "Alex", text: "Moin."),
            TranscriptSegment(start: 2, end: 3, track: .remote, speaker: "Speaker B", text: "Servus."),
        ],
        speakerSuggestions: ["Speaker B": "Alex"]
    )

    guard case .nameSpeaker(_, _, let candidates, _, let suggestion)? =
        SessionCoordinator.namingQuestion(for: transcript, session: transcript.session, calendar: nil)
    else {
        Issue.record("expected a naming question")
        return
    }
    #expect(suggestion == nil)
    #expect(candidates.isEmpty)
}
