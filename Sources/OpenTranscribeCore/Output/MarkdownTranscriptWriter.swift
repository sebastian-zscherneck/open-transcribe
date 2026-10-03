import Foundation

/// Errors surfaced when the wiki inbox itself is unusable. Never silently written elsewhere.
public enum MarkdownWriterError: Error, Sendable, CustomStringConvertible {
    case missingWikiDirectory(URL)

    public var description: String {
        switch self {
        case .missingWikiDirectory(let url):
            return "wiki raw directory does not exist: \(url.path)"
        }
    }
}

/// Renders a `Transcript` into the wiki's frontmatter + timestamped-lines format and writes
/// it atomically into `Paths.wikiRaw`.
public struct MarkdownTranscriptWriter: TranscriptWriting {
    private let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    @discardableResult
    public func write(_ transcript: Transcript, slug: String) throws -> URL {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: paths.wikiRaw.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw MarkdownWriterError.missingWikiDirectory(paths.wikiRaw)
        }

        let baseName = "\(Self.dateComponent(for: transcript.recordedAt))-\(slug)"
        let url = uniqueURL(baseName: baseName)
        try Data(Self.render(transcript).utf8).writeAtomically(to: url)
        return url
    }

    @discardableResult
    public func rewrite(_ transcript: Transcript, at url: URL) throws -> URL {
        try Data(Self.render(transcript).utf8).writeAtomically(to: url)
        return url
    }

    private func uniqueURL(baseName: String) -> URL {
        var candidate = paths.wikiRaw.appendingPathComponent("\(baseName).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = paths.wikiRaw.appendingPathComponent("\(baseName)-\(suffix).md")
            suffix += 1
        }
        return candidate
    }

    /// Exposed `static` (not just internal to `write`) so the golden test can check the
    /// rendered content independent of filesystem side effects.
    static func render(_ transcript: Transcript) -> String {
        let title = transcript.calendarTitle ?? transcript.appName
        let minutes = Int((transcript.duration / 60).rounded())
        let updated = dateComponent(for: transcript.recordedAt)
        let participants = transcript.speakers.joined(separator: ", ")
        let startsAt = timeComponent(for: transcript.recordedAt)
        let endsAt = timeComponent(for: transcript.recordedAt.addingTimeInterval(transcript.duration))

        let important = transcript.importantRanges
        var lines = [
            "---",
            "description: Meeting-Transkript \(title), \(minutes) min",
            "updated: \(updated)",
            "teilnehmer: \(participants)",
            "quelle: open-transcribe (\(transcript.appName), \(startsAt)-\(endsAt))",
        ]
        if !important.isEmpty {
            // Listed up front so the ingest can jump straight to what the speaker flagged.
            let spans = important
                .map { "\(formatOffset($0.start))-\(formatOffset($0.end))" }
                .joined(separator: ", ")
            lines.append("wichtig: \(spans)")
        }
        lines += [
            "---",
            "",
            "> Automatische Transkription, kann Fehler enthalten. Besonders betroffen sind " +
                "englische Fachbegriffe und Eigennamen sowie Stellen, an denen ein Wort nicht " +
                "in den Kontext passt. Im Zweifel gilt das Gesagte, nicht dieser Text.",
            "",
        ]

        for segment in transcript.segments {
            let flagged = important.contains { $0.overlaps(start: segment.start, end: segment.end) }
            let marker = flagged ? "**!** " : ""
            lines.append("\(marker)[\(formatOffset(segment.start))] \(segment.speaker): \(segment.text)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func dateComponent(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func timeComponent(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    /// Timestamps in the body are relative offsets from the meeting start, not wall-clock times.
    private static func formatOffset(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
