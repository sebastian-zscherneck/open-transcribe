import Foundation
import OpenTranscribeCore

/// Debug front end for the daemon. Everything it does goes through the same file IPC the
/// notch UI uses, so using it proves that channel works.
let paths = Paths.live
let queue = CommandQueue(paths: paths)
let args = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    otcli — open-transcribe debug CLI

      status              current daemon state
      start               answer the notch prompt with yes
      discard             answer the notch prompt with no
      pause | resume
      stop                stop and transcribe the running session
      important           flag the last two minutes as important
      finalize <session>  transcribe a recording left behind by a crash
      name <label> <name> assign a name to a speaker of the last transcript
      sessions            recordings still on disk
      processes           processes CoreAudio currently sees, and who holds the microphone
      miccheck [seconds]  hold the microphone for a while, to exercise detection end to end
      capturecheck [seconds] [bundleID]
                          runs both capture sources through the running app (which has mic and
                          audio-capture permission, unlike this CLI) and reports sample count,
                          peak and RMS per track to capture-check.log

      transcribe <mic.wav> <remote.wav> [outDir] [--learn "Speaker A=Anna,Speaker B=Tom"]
                          run the real pipeline (models, diarization, title, markdown)
                          on two existing tracks. Writes into outDir, default is the wiki.
                          --learn stores the voices under those names, so a later run
                          recognises them by itself.
    """)
}

/// Full pipeline on files that already exist. This is how the transcription half gets exercised
/// against real audio and real models without having to sit through a meeting.
/// stdout is a pipe in most runs, so progress has to be flushed to be seen while it happens.
func progress(_ message: String) {
    print(message)
    fflush(stdout)
}

func transcribeFiles(mic: String, remote: String, outDir: String?, learn: [String: String] = [:]) async throws {
    let outPaths: Paths
    if let outDir {
        let url = URL(fileURLWithPath: outDir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        outPaths = Paths(root: paths.root, wikiRaw: url)
    } else {
        outPaths = paths
    }

    let profiles = ProfileStore(paths: outPaths)
    let transcriber = FluidTranscriber(profiles: profiles)

    progress("loading models…")
    let modelStart = Date()
    try await transcriber.prepare()
    progress(String(format: "models ready in %.1fs", Date().timeIntervalSince(modelStart)))

    var tracks: [Track: URL] = [:]
    if FileManager.default.fileExists(atPath: mic) { tracks[.mic] = URL(fileURLWithPath: mic) }
    if FileManager.default.fileExists(atPath: remote) { tracks[.remote] = URL(fileURLWithPath: remote) }
    guard !tracks.isEmpty else { throw CocoaError(.fileNoSuchFile) }

    let session = SessionID(date: Date())
    let passStart = Date()
    let transcript = try await transcriber.finalPass(
        tracks: tracks,
        context: FinalPassContext(
            session: session,
            recordedAt: Date(),
            appName: "otcli",
            calendar: nil,
            ownerName: "Sebastian"
        )
    )
    let terms = PersonalDictionary.load(paths: outPaths)
    let corrected: Transcript
    if #available(macOS 26.0, *), !terms.isEmpty {
        progress("correcting \(terms.count) known terms…")
        corrected = await FoundationModelsCorrector(
            terms: terms, aliases: PersonalDictionary.loadAliases(paths: outPaths)
        ).correct(transcript)
    } else {
        corrected = transcript
    }

    progress(String(format: "transcribed in %.1fs, %d segments, speakers: %@",
                 Date().timeIntervalSince(passStart),
                 transcript.segments.count,
                 transcript.speakers.joined(separator: ", ")))
    for (label, name) in transcript.speakerSuggestions.sorted(by: { $0.key < $1.key }) {
        progress("\(label) sounds like \(name) (see ~/.opentranscribe/logs/speakers.log for distances)")
    }

    for (label, name) in learn.sorted(by: { $0.key < $1.key }) {
        await transcriber.learn(label: label, as: name)
        progress("learned \(label) as \(name)")
    }

    let slug = await ClaudeTitleGenerator().slug(for: corrected)
    let url = try MarkdownTranscriptWriter(paths: outPaths).write(corrected, slug: slug)
    progress("wrote \(url.path)")
}

/// Dumps what the detector sees. The fastest way to tell whether a meeting app is recognised
/// and whether an ignore-list entry is doing its job.
func printProcesses() throws {
    let settings = DetectionSettings.load(from: paths)
    let snapshots = try CoreAudioProcessSource().snapshot()
    guard !snapshots.isEmpty else {
        print("CoreAudio reports no audio processes")
        return
    }
    for snapshot in snapshots.sorted(by: { $0.bundleID < $1.bundleID }) {
        let role: String
        if settings.isIgnored(snapshot.bundleID) {
            role = "ignored"
        } else if let trigger = settings.trigger(for: snapshot.bundleID) {
            role = trigger == snapshot.bundleID ? "trigger" : "→ \(trigger)"
        } else {
            role = "-"
        }
        let mic = snapshot.isRunningInput ? "MIC" : "   "
        print("\(mic)  \(role.padding(toLength: 22, withPad: " ", startingAt: 0))  \(snapshot.bundleID)  pid \(snapshot.pid)")
    }
}

/// Opens the microphone and keeps it open. Used to drive the detector with a real capturing
/// process instead of a fake snapshot.
func micCheck(seconds: TimeInterval) async throws {
    let capture = AudioCaptureCoordinator(paths: paths)
    let app = MeetingApp(bundleID: "com.mitchellh.ghostty", name: "Terminal", pid: getpid())
    try await capture.startPrerollBuffer(app: app)
    progress("microphone open for \(Int(seconds))s")
    try await Task.sleep(for: .seconds(seconds))
    let samples = await capture.recentSamples(track: .mic, seconds: 3)
    await capture.discardPreroll()
    let peak = samples.map { abs($0) }.max() ?? 0
    progress(String(format: "captured %d samples in the last 3s, peak amplitude %.4f", samples.count, peak))
}

/// Sends `debugCapture` and waits for the daemon to finish it, then prints its result line.
/// The wait is a plain sleep rather than polling: the daemon runs the check for exactly
/// `seconds` and appends to the log once, so there is nothing to poll for.
func captureCheck(seconds: Int, bundleID: String?) async throws {
    try queue.send(.debugCapture(seconds: seconds, bundleID: bundleID))
    progress("checking capture for \(seconds)s (through the running app, not this CLI)…")
    try await Task.sleep(for: .seconds(seconds + 3))

    let logURL = paths.logsDir.appendingPathComponent("capture-check.log")
    guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else {
        print("no capture-check.log yet — is the daemon running? (otcli status)")
        return
    }
    let lastLine = contents.split(separator: "\n").last ?? "(log is empty)"
    print(lastLine)
}

func printStatus() {
    let state = StateStore.loadPersisted(paths: paths)
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss"

    print("phase:    \(state.phase.rawValue)")
    if let app = state.app { print("app:      \(app.name) (\(app.bundleID))") }
    if let session = state.session { print("session:  \(session.raw)") }
    if let started = state.startedAt {
        let minutes = Int(Date().timeIntervalSince(started) / 60)
        print("running:  \(minutes) min (since \(fmt.string(from: started)))")
    }
    if let calendar = state.calendar {
        print("calendar: \(calendar.title) — \(calendar.attendees.joined(separator: ", "))")
    }
    if let question = state.pendingQuestion { print("question: \(question)") }
    if let file = state.lastWrittenFile { print("written:  \(file)") }
    if let error = state.error { print("error:    [\(error.code)] \(error.message)") }
    if !state.recentLines.isEmpty {
        print("recent:")
        for line in state.recentLines { print("  \(line.speaker): \(line.text)") }
    }
    print("updated:  \(fmt.string(from: state.updatedAt))")
}

func printSessions() {
    let fm = FileManager.default
    let dirs = (try? fm.contentsOfDirectory(atPath: paths.recordingsDir.path)) ?? []
    if dirs.isEmpty {
        print("no recordings on disk")
        return
    }
    for dir in dirs.sorted() {
        let session = SessionID(raw: dir)
        let meta = RecordingMeta.load(paths: paths, session: session)
        let size = [Track.mic, .remote]
            .compactMap { try? fm.attributesOfItem(atPath: paths.trackFile(session, $0).path)[.size] as? Int64 }
            .reduce(0, +)
        let mb = String(format: "%.1f", Double(size) / 1_000_000)
        print("\(dir)  \(meta?.appName ?? "?")  \(mb) MB")
    }
}

do {
    switch args.first {
    case "status", nil:
        printStatus()
    case "start":
        try queue.send(.start)
    case "discard":
        try queue.send(.discard)
    case "pause":
        try queue.send(.pause)
    case "resume":
        try queue.send(.resume)
    case "stop":
        try queue.send(.stop)
    case "important":
        try queue.send(.markImportant)
    case "sessions":
        printSessions()
    case "processes":
        try printProcesses()
    case "miccheck":
        try await micCheck(seconds: args.count > 1 ? (Double(args[1]) ?? 30) : 30)
    case "capturecheck":
        let seconds = args.count > 1 ? (Int(args[1]) ?? 10) : 10
        let bundleID = args.count > 2 ? args[2] : nil
        try await captureCheck(seconds: seconds, bundleID: bundleID)
    case "transcribe":
        guard args.count >= 3 else { printUsage(); exit(1) }
        // Top-level code in main.swift can await directly, and must: it runs on the main actor,
        // so parking it on a semaphore would deadlock the task it is waiting for.
        let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
        var learn: [String: String] = [:]
        if let index = args.firstIndex(of: "--learn"), args.count > index + 1 {
            for pair in args[index + 1].split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                learn[String(parts[0])] = String(parts[1])
            }
        }
        try await transcribeFiles(
            mic: positional[positional.startIndex],
            remote: positional[positional.index(after: positional.startIndex)],
            outDir: positional.count > 2 ? positional[positional.index(positional.startIndex, offsetBy: 2)] : nil,
            learn: learn
        )
    case "finalize":
        guard args.count == 2 else { printUsage(); exit(1) }
        try queue.send(.finalize(session: SessionID(raw: args[1])))
    case "name":
        guard args.count == 3, let session = StateStore.loadPersisted(paths: paths).session else {
            printUsage()
            exit(1)
        }
        try queue.send(.assignSpeaker(session: session, label: args[1], name: args[2]))
    default:
        printUsage()
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("otcli: \(error)\n".utf8))
    exit(1)
}
