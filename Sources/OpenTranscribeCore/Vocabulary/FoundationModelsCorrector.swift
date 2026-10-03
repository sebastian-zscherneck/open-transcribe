import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runs each transcript segment through Apple's on-device model to repair domain terms it
/// mistranscribed, then guards the result through `CorrectionGuard` before it can land.
///
/// A fresh `LanguageModelSession` per segment is deliberate: a shared session drifts and
/// answers with stale context far more often than a clean one per call. Any model failure —
/// most notably `guardrailViolation`, which the base model throws on some entirely harmless
/// business sentences — or a timeout falls back to the original segment in silence. This is
/// a best-effort polish pass, never a reason to lose or block a transcript.
public struct FoundationModelsCorrector: TranscriptCorrecting {
    private let terms: [String]
    private let timeout: TimeInterval
    private let minWordCount: Int
    private let maxPasses: Int

    /// `maxPasses` exists because the on-device model is not deterministic: on a sentence with two
    /// wrong terms it often repairs only one, and repairs the other on the next attempt. Every
    /// change still has to survive `CorrectionGuard`, so asking again costs a second but cannot
    /// make the text worse.
    private let aliases: VocabularyAliases

    public init(
        terms: [String],
        aliases: VocabularyAliases = VocabularyAliases(),
        timeout: TimeInterval = 5,
        minWordCount: Int = 3,
        maxPasses: Int = 3
    ) {
        self.aliases = aliases
        self.terms = terms
        self.timeout = timeout
        self.minWordCount = minWordCount
        self.maxPasses = max(1, maxPasses)
    }

    public func correct(_ transcript: Transcript) async -> Transcript {
        guard !terms.isEmpty else { return transcript }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), Self.modelAvailable else { return transcript }

        var corrected = transcript
        for index in corrected.segments.indices {
            let original = corrected.segments[index].text
            guard wordCount(original) >= minWordCount else { continue }
            // Skip the model entirely where no word even resembles a term. Saves most of the
            // wall clock on a long meeting, and cannot lose a correction: the guard would have
            // rejected anything from these segments anyway.
            guard CorrectionCandidates.mayContainTerm(original, terms: terms, aliases: aliases) else { continue }

            var text = original
            for _ in 0..<maxPasses {
                guard let proposal = await correctSegment(text) else { break }
                let accepted = CorrectionGuard.apply(
                    original: text, proposal: proposal, terms: terms, aliases: aliases
                )
                // Nothing new survived the guard, so another attempt would repeat itself.
                if accepted == text { break }
                text = accepted
            }
            guard text != original else { continue }

            let segment = corrected.segments[index]
            corrected.segments[index] = TranscriptSegment(
                start: segment.start,
                end: segment.end,
                track: segment.track,
                speaker: segment.speaker,
                text: text
            )
        }
        return corrected
        #else
        return transcript
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static var modelAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @available(macOS 26.0, *)
    private func correctSegment(_ text: String) async -> String? {
        let terms = self.terms
        let hints = Self.aliasHints(aliases)
        let timeout = self.timeout
        return try? await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: Self.instructions(terms: terms, hints: hints))
                let response = try await session.respond(to: text)
                return response.content
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            defer { group.cancelAll() }
            // First to finish wins: either the model's answer or the timeout's `nil`.
            // Any thrown error (guardrailViolation included) propagates out of the group
            // and is swallowed by the `try?` above, falling back to the original segment.
            for try await value in group {
                return value
            }
            return nil
        }
    }

    @available(macOS 26.0, *)
    /// Known mishearings, spelled out for the model. It repairs far more of them when it is told
    /// what the recogniser tends to produce instead of the term.
    static func aliasHints(_ aliases: VocabularyAliases) -> String {
        let pairs = aliases.entries
            .sorted { $0.key < $1.key }
            .map { "\($0.value.joined(separator: ", ")) -> \($0.key)" }
        return pairs.isEmpty ? "" : "Typische Verhörer: " + pairs.joined(separator: "; ") + "."
    }

    @available(macOS 26.0, *)
    private static func instructions(terms: [String], hints: String) -> String {
        """
        Du korrigierst ausschließlich falsch erkannte Fachbegriffe und Eigennamen in einem \
        deutschen Meeting-Transkript-Segment. Ändere sonst nichts: keine Umformulierung, \
        keine Grammatik- oder Stilkorrekturen, keine hinzugefügten oder gelöschten Sätze.
        Bekannte Begriffe: \(terms.joined(separator: ", ")).
        \(hints)

        Beispiele:
        "Wir schauen uns kurz Amazon das Boat an." -> "Wir schauen uns kurz Amazon Dashboard an."
        "Das Passwort liegt in Bitwarten." -> "Das Passwort liegt in Bitwarden."
        "Das Projekt läuft gerade sehr gut." -> "Das Projekt läuft gerade sehr gut."

        Gib ausschließlich den korrigierten Satz zurück, ohne Anführungszeichen, ohne \
        Erklärung.
        """
    }
    #endif

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
