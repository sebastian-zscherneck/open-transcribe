import Foundation

/// Removes phrases the transcription repeated at a chunk boundary.
///
/// Long recordings are transcribed in overlapping windows, and the overlap comes back as a
/// duplicated phrase: "ich kann dir das auch mal kurz ich kann dir das auch mal kurz zeigen".
/// Real speakers do repeat themselves, so this only collapses a repetition that follows itself
/// immediately, optionally with a couple of filler words wedged in between — the shape an
/// overlap artifact has, not the shape of someone making a point twice.
public enum RepetitionCleaner {
    /// Longest phrase considered, in words.
    private static let maxPhrase = 8
    /// Shortest phrase considered. Two words keeps "das das" out of scope but catches real cases.
    private static let minPhrase = 2
    /// How many words may sit between the two occurrences.
    private static let maxGap = 3

    public static func clean(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0 == " " }).map(String.init)
        guard words.count >= minPhrase * 2 else { return text }

        var changed = true
        var rounds = 0
        while changed, rounds < 8 {
            changed = false
            rounds += 1
            outer: for length in stride(from: min(maxPhrase, words.count / 2), through: minPhrase, by: -1) {
                for start in 0...(words.count - length * 2) {
                    let phrase = words[start..<(start + length)].map(normalized)
                    for gap in 0...maxGap {
                        let secondStart = start + length + gap
                        guard secondStart + length <= words.count else { continue }
                        let candidate = words[secondStart..<(secondStart + length)].map(normalized)
                        guard phrase == candidate, phrase.allSatisfy({ !$0.isEmpty }) else { continue }
                        // Keep the second occurrence: it carries the punctuation and continues
                        // into the rest of the sentence.
                        words.removeSubrange(start..<secondStart)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return words.joined(separator: " ")
    }

    private static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
