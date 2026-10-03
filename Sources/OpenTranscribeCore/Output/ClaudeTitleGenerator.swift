import Foundation

/// Injectable process-execution seam so tests never spawn a real process.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ args: [String], stdin: String?, timeout: TimeInterval) throws -> String
}

/// Errors raised while resolving or running an external command.
public enum CommandRunnerError: Error, Sendable, CustomStringConvertible {
    case notFound(String)
    case timedOut
    case nonZeroExit(Int32, String)

    public var description: String {
        switch self {
        case .notFound(let executable): return "executable not found: \(executable)"
        case .timedOut: return "command timed out"
        case .nonZeroExit(let code, let output): return "exit \(code): \(output)"
        }
    }
}

/// Real `CommandRunning` backed by `Process`. Looks for the executable on `PATH` and,
/// as a fallback, under `~/.local/bin` — where the `claude` CLI often ends up installed.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ args: [String], stdin: String?, timeout: TimeInterval) throws -> String {
        guard let executableURL = Self.resolve(executable) else {
            throw CommandRunnerError.notFound(executable)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        if let stdin, let data = stdin.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        // Output is expected to be a short slug, so blocking on termination before draining
        // the pipe is safe: it will never fill the 64 KB pipe buffer.
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminationHandler = nil
            process.terminate()
            throw CommandRunnerError.timedOut
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? ""
            throw CommandRunnerError.nonZeroExit(process.terminationStatus, errorString)
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private static func resolve(_ executable: String) -> URL? {
        let fileManager = FileManager.default

        let localBin = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/\(executable)")
        if fileManager.isExecutableFile(atPath: localBin.path) {
            return localBin
        }

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(executable)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Generates a wiki filename slug by asking the headless `claude` CLI for a short summary
/// of the transcript's opening. Never throws: any failure (missing CLI, timeout, non-zero
/// exit, unusable answer) falls back to `Slug.fallback` silently.
public struct ClaudeTitleGenerator: TitleGenerating {
    private let runner: CommandRunning
    private let executable: String
    private let timeout: TimeInterval

    public init(
        runner: CommandRunning = ProcessCommandRunner(),
        executable: String = "claude",
        timeout: TimeInterval = 30
    ) {
        self.runner = runner
        self.executable = executable
        self.timeout = timeout
    }

    public func slug(for transcript: Transcript) async -> String {
        let excerpt = excerpt(from: transcript)
        let prompt = Self.prompt(for: excerpt)

        guard let raw = try? runner.run(executable, ["-p", prompt], stdin: nil, timeout: timeout) else {
            return fallback(for: transcript)
        }

        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = Slug.normalize(cleaned) else {
            return fallback(for: transcript)
        }
        return normalized
    }

    private func fallback(for transcript: Transcript) -> String {
        Slug.fallback(appName: transcript.appName, at: transcript.recordedAt)
    }

    private func excerpt(from transcript: Transcript) -> String {
        let full = transcript.segments
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        return String(full.prefix(3000))
    }

    private static func prompt(for excerpt: String) -> String {
        """
        Du bekommst den Anfang eines Meeting-Transkripts. Antworte AUSSCHLIESSLICH mit einem \
        kebab-case-Slug aus 2 bis 4 Wörtern (nur Kleinbuchstaben a-z, Ziffern und Bindestriche, \
        keine Erklärung, kein Satzzeichen, keine Anführungszeichen), der das Thema des Meetings \
        zusammenfasst.

        Transkript:
        \(excerpt)
        """
    }
}
