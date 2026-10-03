import Foundation

/// Abstracts a live audio source that produces 16 kHz mono Float32 chunks, so the coordinator
/// can be driven by a scripted fake in tests instead of real CoreAudio/AVAudioEngine hardware.
public protocol CaptureSource: Sendable {
    /// Begins delivering sample chunks to `onSamples` until `stop()` is called. Real
    /// implementations receive samples on a realtime audio thread and must bridge into this
    /// `async` callback themselves (e.g. via an unstructured `Task`) rather than blocking that
    /// thread; the callback itself must never hop to the main actor.
    func start(onSamples: @escaping @Sendable ([Float]) async -> Void) throws
    /// Stops delivering samples and releases hardware resources. Safe to call even if `start`
    /// was never called or already stopped.
    func stop()
}

/// Owns both capture tracks (mic + remote), the RAM preroll buffers, and the on-disk WAV
/// writers. An actor, so every transition (`startPrerollBuffer`, `commitToDisk`, `pause`, ...)
/// is serialized against concurrent audio callbacks without ever hopping to the main actor.
public actor AudioCaptureCoordinator: AudioCapturing {
    public enum CoordinatorError: Error, Sendable, Equatable {
        case alreadyActive
        case notPrerolling
        case notRecording
    }

    private enum State {
        case idle
        case prerolling(app: MeetingApp)
        case recording(session: SessionID)
        case paused(session: SessionID)
    }

    private let paths: Paths
    private let prerollSeconds: TimeInterval
    private let makeMicSource: @Sendable () -> CaptureSource
    private let makeRemoteSource: @Sendable (MeetingApp) -> CaptureSource

    private var state: State = .idle
    private var micSource: CaptureSource?
    private var remoteSource: CaptureSource?
    private var micPreroll: PrerollBuffer
    private var remotePreroll: PrerollBuffer
    private var micWriter: WAVWriter?
    private var remoteWriter: WAVWriter?

    public init(
        paths: Paths,
        prerollSeconds: TimeInterval = 90,
        makeMicSource: @escaping @Sendable () -> CaptureSource = { MicCapture() },
        makeRemoteSource: @escaping @Sendable (MeetingApp) -> CaptureSource = { ProcessTapCapture(app: $0) }
    ) {
        self.paths = paths
        self.prerollSeconds = prerollSeconds
        self.makeMicSource = makeMicSource
        self.makeRemoteSource = makeRemoteSource
        self.micPreroll = PrerollBuffer(seconds: prerollSeconds)
        self.remotePreroll = PrerollBuffer(seconds: prerollSeconds)
    }

    public func startPrerollBuffer(app: MeetingApp) async throws {
        guard case .idle = state else { throw CoordinatorError.alreadyActive }

        micPreroll = PrerollBuffer(seconds: prerollSeconds)
        remotePreroll = PrerollBuffer(seconds: prerollSeconds)

        let mic = makeMicSource()
        try mic.start { [weak self] samples in
            await self?.ingest(samples, track: .mic)
        }

        let remote = makeRemoteSource(app)
        do {
            try remote.start { [weak self] samples in
                await self?.ingest(samples, track: .remote)
            }
        } catch {
            mic.stop()
            throw error
        }

        micSource = mic
        remoteSource = remote
        state = .prerolling(app: app)
    }

    public func commitToDisk(session: SessionID) async throws {
        guard case .prerolling = state else { throw CoordinatorError.notPrerolling }

        try paths.createDirectories()
        try FileManager.default.createDirectory(
            at: paths.sessionDir(session), withIntermediateDirectories: true)

        let mic = try WAVWriter(url: paths.trackFile(session, .mic))
        let remote = try WAVWriter(url: paths.trackFile(session, .remote))

        // The preroll content becomes the start of the file before any further streaming.
        try await mic.write(micPreroll.peek())
        try await remote.write(remotePreroll.peek())

        micWriter = mic
        remoteWriter = remote
        state = .recording(session: session)
    }

    public func discardPreroll() async {
        guard case .prerolling = state else { return }
        micSource?.stop()
        remoteSource?.stop()
        micSource = nil
        remoteSource = nil
        micPreroll = PrerollBuffer(seconds: prerollSeconds)
        remotePreroll = PrerollBuffer(seconds: prerollSeconds)
        state = .idle
    }

    public func pause() async {
        guard case .recording(let session) = state else { return }
        state = .paused(session: session)
    }

    public func resume() async throws {
        guard case .paused(let session) = state else { throw CoordinatorError.notRecording }
        state = .recording(session: session)
    }

    public func stop() async throws -> [Track: URL] {
        switch state {
        case .recording(let session), .paused(let session):
            micSource?.stop()
            remoteSource?.stop()
            await micWriter?.close()
            await remoteWriter?.close()
            let tracks: [Track: URL] = [
                .mic: paths.trackFile(session, .mic),
                .remote: paths.trackFile(session, .remote),
            ]
            micSource = nil
            remoteSource = nil
            micWriter = nil
            remoteWriter = nil
            state = .idle
            return tracks
        case .idle, .prerolling:
            throw CoordinatorError.notRecording
        }
    }

    public func recentSamples(track: Track, seconds: TimeInterval) async -> [Float] {
        let buffer = track == .mic ? micPreroll : remotePreroll
        let sampleCount = Int(seconds * PrerollBuffer.sampleRate)
        return Array(buffer.peek().suffix(sampleCount))
    }

    /// Fans an incoming chunk out to the live preview buffer and, while actively recording,
    /// to the on-disk writer. Runs on the actor's own executor, never the main actor.
    private func ingest(_ samples: [Float], track: Track) async {
        switch state {
        case .idle:
            return
        case .prerolling, .paused:
            append(samples, track: track)
        case .recording:
            append(samples, track: track)
            do {
                if track == .mic {
                    try await micWriter?.write(samples)
                } else {
                    try await remoteWriter?.write(samples)
                }
            } catch {
                // Persistent write failures surface through state.json elsewhere; capture
                // must not crash on a transient disk hiccup.
            }
        }
    }

    private func append(_ samples: [Float], track: Track) {
        if track == .mic {
            micPreroll.append(samples)
        } else {
            remotePreroll.append(samples)
        }
    }
}
