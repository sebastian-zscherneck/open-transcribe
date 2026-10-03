import Foundation

/// Commits and pushes a freshly written transcript.
///
/// Writing the file locally is not enough: the ingest that turns a transcript into wiki pages,
/// a report and Linear issues runs on a VPS and pulls from GitHub. Without this step a meeting
/// would sit in `raw/` forever and look processed while nothing ever happened.
public protocol WikiPublishing: Sendable {
    /// Returns nil on success, or a human-readable reason the file is not published yet.
    func publish(_ file: URL) async -> String?
}

public struct GitWikiPublisher: WikiPublishing {
    private let repository: URL
    private let runner: CommandRunning
    private let timeout: TimeInterval

    public init(repository: URL, runner: CommandRunning = ProcessCommandRunner(), timeout: TimeInterval = 60) {
        self.repository = repository
        self.runner = runner
        self.timeout = timeout
    }

    public func publish(_ file: URL) async -> String? {
        let relative = file.path.replacingOccurrences(of: repository.path + "/", with: "")
        let message = "ingest: Meeting-Transkript \(file.deletingPathExtension().lastPathComponent)"

        // Pull first: the same repository is written from the VPS, and a rejected push would
        // otherwise leave the transcript stranded locally.
        let steps: [[String]] = [
            ["-C", repository.path, "pull", "--rebase", "--autostash"],
            ["-C", repository.path, "add", "--", relative],
            ["-C", repository.path, "commit", "-m", message, "--", relative],
            ["-C", repository.path, "push"],
        ]

        for arguments in steps {
            do {
                _ = try runner.run("git", arguments, stdin: nil, timeout: timeout)
            } catch {
                return "Transkript liegt in \(relative), ist aber noch nicht gepusht: git \(arguments.first ?? "?") schlug fehl (\(error))"
            }
        }
        return nil
    }
}
