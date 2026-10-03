import Foundation

/// One person's stored voice profile. The embedding is a running mean over every sample folded
/// in via `remember`, weighted by `sampleCount` so a long history isn't swamped by one bad sample.
struct SpeakerProfile: Codable, Sendable {
    let name: String
    var embedding: [Float]
    var sampleCount: Int
}

/// Persistent voice profiles as one JSON file per person under `Paths.profilesDir`.
///
/// Matching uses cosine *distance* (`1 - cosineSimilarity`), the same convention FluidAudio's
/// `SpeakerManager` uses internally. Lower distance means more similar. A cluster is recognised
/// as the closest profile only when that profile is within `threshold` *and* the runner-up is at
/// least `margin` further away. Different people's profiles have been measured only ~0.7 apart,
/// so FluidAudio's within-meeting default of 0.65 let a stranger pass as a known person; the
/// margin stops a coin-flip between two near-equal profiles from being called a match.
///
/// Every attempt is appended to `logs/speakers.log` with all distances, so a wrong name can be
/// traced to numbers instead of guessed at.
public actor ProfileStore: SpeakerProfiling {
    private let profilesDir: URL
    private let logURL: URL
    private let threshold: Float
    private let margin: Float

    public init(paths: Paths, threshold: Float = 0.5, margin: Float = 0.1) {
        self.profilesDir = paths.profilesDir
        self.logURL = paths.logsDir.appendingPathComponent("speakers.log")
        self.threshold = threshold
        self.margin = margin
    }

    public func match(embedding: [Float]) async -> SpeakerMatch? {
        let ranked = loadAllProfiles()
            .map { SpeakerMatch(name: $0.name, distance: Self.cosineDistance(embedding, $0.embedding)) }
            .sorted { $0.distance < $1.distance }

        let result = Self.decide(ranked: ranked, threshold: threshold, margin: margin)
        log(ranked: ranked, result: result)
        return result
    }

    /// Pure decision over already-sorted candidates, so the rule is testable without files.
    static func decide(ranked: [SpeakerMatch], threshold: Float, margin: Float) -> SpeakerMatch? {
        guard let best = ranked.first, best.distance <= threshold else { return nil }
        if ranked.count > 1, ranked[1].distance - best.distance < margin { return nil }
        return best
    }

    private func log(ranked: [SpeakerMatch], result: SpeakerMatch?) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let distances = ranked.map { String(format: "%@ %.2f", $0.name, $0.distance) }.joined(separator: ", ")
        let verdict = result.map { "-> \($0.name)" } ?? "-> unknown"
        let line = "\(stamp) [\(distances)] \(verdict)\n"

        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    public func remember(name: String, embedding: [Float]) async throws {
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)

        let url = profileURL(for: name)
        let updated: SpeakerProfile
        if let existing = loadProfile(at: url) {
            let count = Float(existing.sampleCount)
            let averaged = zip(existing.embedding, embedding).map { ($0 * count + $1) / (count + 1) }
            updated = SpeakerProfile(name: name, embedding: averaged, sampleCount: existing.sampleCount + 1)
        } else {
            updated = SpeakerProfile(name: name, embedding: embedding, sampleCount: 1)
        }

        let data = try OTJSON.encoder.encode(updated)
        try data.writeAtomically(to: url)
    }

    public func knownNames() async -> [String] {
        loadAllProfiles().map(\.name).sorted()
    }

    // MARK: - Storage

    private func profileURL(for name: String) -> URL {
        profilesDir.appendingPathComponent("\(Self.slug(name)).json")
    }

    private func loadProfile(at url: URL) -> SpeakerProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? OTJSON.decoder.decode(SpeakerProfile.self, from: data)
    }

    private func loadAllProfiles() -> [SpeakerProfile] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: profilesDir, includingPropertiesForKeys: nil
            )
        else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { loadProfile(at: $0) }
    }

    /// Filesystem-safe filename stem for a display name. The original name is preserved inside
    /// the JSON payload; this only needs to be stable and collision-free for common names.
    private static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(mapped)
        return collapsed.isEmpty ? "unnamed" : collapsed
    }

    // MARK: - Similarity

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return .infinity }

        let similarity = dot / (normA.squareRoot() * normB.squareRoot())
        return 1 - similarity
    }
}
