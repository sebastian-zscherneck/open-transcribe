import Foundation

/// Drop-file command channel between the notch UI and the daemon.
///
/// The UI writes one JSON file per command, the daemon consumes and deletes it. No XPC, no
/// entitlements, no signing dance, and every command is visible on disk while debugging.
public struct CommandQueue: Sendable {
    private let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// UI side: enqueue a command for the daemon.
    public func send(_ command: Command) throws {
        try FileManager.default.createDirectory(at: paths.commandsDir, withIntermediateDirectories: true)
        let url = paths.commandsDir.appendingPathComponent("\(UUID().uuidString).json")
        try OTJSON.encoder.encode(command).writeAtomically(to: url)
    }

    /// Daemon side: take everything pending, oldest first, and remove it from the queue.
    /// Unreadable files are deleted rather than retried, so one bad file cannot wedge the queue.
    public func drain() -> [Command] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.commandsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sorted = entries
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l < r
            }

        var commands: [Command] = []
        for url in sorted {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let command = try? OTJSON.decoder.decode(Command.self, from: data)
            else { continue }
            commands.append(command)
        }
        return commands
    }
}
