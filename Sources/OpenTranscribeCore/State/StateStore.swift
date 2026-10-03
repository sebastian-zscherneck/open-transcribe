import Foundation

/// Owns `state.json`. Every phase transition goes through here so the notch UI always
/// sees a consistent picture, even if the daemon dies right after the write.
public actor StateStore {
    private let paths: Paths
    private var state: DaemonState

    public init(paths: Paths, initial: DaemonState = DaemonState()) {
        self.paths = paths
        self.state = initial
    }

    public var current: DaemonState { state }

    /// Applies a mutation and persists the result atomically.
    @discardableResult
    public func update(_ mutate: @Sendable (inout DaemonState) -> Void) throws -> DaemonState {
        mutate(&state)
        state.updatedAt = Date()
        try persist()
        return state
    }

    /// Rewrites the state file with a fresh timestamp and nothing else changed.
    public func touch() throws {
        try update { _ in }
    }

    public func transition(to phase: Phase) throws {
        try update { $0.phase = phase }
    }

    public func fail(code: String, message: String, recoverable: Bool) throws {
        try update {
            $0.phase = .error
            $0.error = DaemonError(code: code, message: message, recoverable: recoverable)
        }
    }

    /// Surfaces a problem without ending what is going on. A silent microphone is worth shouting
    /// about, but stopping the recording over it would throw away the other track too.
    public func warn(code: String, message: String) throws {
        try update {
            $0.error = DaemonError(code: code, message: message, recoverable: true)
        }
    }

    public func clearError() throws {
        try update { $0.error = nil }
    }

    /// Keeps the last `limit` preview lines in the state file. The full live transcript
    /// lives in `transcript.live.jsonl`, this is only what the panel renders.
    public func appendLiveLines(_ lines: [LiveLine], limit: Int = 6) throws {
        guard !lines.isEmpty else { return }
        try update {
            $0.recentLines = Array(($0.recentLines + lines).suffix(limit))
        }
    }

    public func reset() throws {
        state = DaemonState()
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try OTJSON.encoder.encode(state).writeAtomically(to: paths.stateFile)
    }

    /// Reads whatever the last daemon run left behind. Returns a fresh state when the file
    /// is missing or unreadable, because a broken state file must never block startup.
    public static func loadPersisted(paths: Paths) -> DaemonState {
        guard let data = try? Data(contentsOf: paths.stateFile),
              let decoded = try? OTJSON.decoder.decode(DaemonState.self, from: data)
        else { return DaemonState() }
        return decoded
    }
}
