import Foundation

/// Every path the daemon touches. Injectable so tests never write to the real home directory.
public struct Paths: Sendable {
    public let root: URL
    public let wikiRaw: URL

    public init(root: URL, wikiRaw: URL) {
        self.root = root
        self.wikiRaw = wikiRaw
    }

    public static var live: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(
            root: home.appendingPathComponent(".opentranscribe", isDirectory: true),
            wikiRaw: home.appendingPathComponent("work/hq-wiki/raw", isDirectory: true)
        )
    }

    public var stateFile: URL { root.appendingPathComponent("state.json") }
    public var commandsDir: URL { root.appendingPathComponent("commands", isDirectory: true) }
    public var liveTranscript: URL { root.appendingPathComponent("transcript.live.jsonl") }
    public var recordingsDir: URL { root.appendingPathComponent("recordings", isDirectory: true) }
    public var profilesDir: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }

    public func sessionDir(_ session: SessionID) -> URL {
        recordingsDir.appendingPathComponent(session.raw, isDirectory: true)
    }

    public func trackFile(_ session: SessionID, _ track: Track) -> URL {
        sessionDir(session).appendingPathComponent("\(track.rawValue).wav")
    }

    public func metaFile(_ session: SessionID) -> URL {
        sessionDir(session).appendingPathComponent("meta.json")
    }

    /// Creates every directory the daemon expects to exist.
    public func createDirectories() throws {
        for dir in [root, commandsDir, recordingsDir, profilesDir, logsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Shared JSON coding so every module reads and writes the same date format.
public enum OTJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension Data {
    /// Writes atomically: temp file in the same directory, then rename.
    /// A crash mid-write can never leave a half-written state file behind.
    public func writeAtomically(to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
