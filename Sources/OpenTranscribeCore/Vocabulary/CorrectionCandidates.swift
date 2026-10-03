import Foundation

/// Decides whether a segment is worth an LLM call at all.
///
/// Correction costs roughly half a second per segment, so a one hour meeting with a few hundred
/// segments would spend minutes in the model before the transcript reaches the wiki. Almost none
/// of those segments contain a mangled domain term. This filter keeps only the ones where some
/// word actually resembles a dictionary entry — the same distance rule the guard applies later,
/// so a segment it rejects could never have produced an accepted correction anyway.
public enum CorrectionCandidates {
    /// Longest word span checked against a term. "Amazon das Boat" needs two, three is headroom.
    private static let maxSpanWords = 3

    public static func mayContainTerm(
        _ text: String,
        terms: [String],
        aliases: VocabularyAliases = VocabularyAliases()
    ) -> Bool {
        guard !terms.isEmpty else { return false }

        // A declared mishearing is a candidate by definition, however far from the term it looks.
        let folded = VocabularyAliases.fold(text)
        for alias in aliases.termsByAlias().keys where !alias.isEmpty {
            if folded.contains(alias) { return true }
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return false }

        // Words that already spell a term. A span touching one of them looks similar to that
        // term by construction, which would make every correctly written term a false positive.
        var settled = Set<Int>()
        for start in words.indices {
            for length in 1...maxSpanWords where start + length <= words.count {
                let span = words[start..<(start + length)].joined(separator: " ")
                if terms.contains(where: { CorrectionGuard.isExactly(span, term: $0) }) {
                    settled.formUnion(start..<(start + length))
                }
            }
        }

        for start in words.indices where !settled.contains(start) {
            for length in 1...maxSpanWords where start + length <= words.count {
                let range = start..<(start + length)
                guard !range.contains(where: settled.contains) else { continue }
                let span = words[range].joined(separator: " ")
                if terms.contains(where: { CorrectionGuard.soundsLike(span, term: $0, amongst: terms) }) {
                    return true
                }
            }
        }
        return false
    }
}
