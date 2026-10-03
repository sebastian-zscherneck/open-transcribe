import Foundation

/// Decides which parts of an LLM's proposed correction are actually allowed to land.
///
/// Pure and synchronous by design: the LLM is untrusted (it rewords, it drops guardrails
/// occasionally), so every word it changes must independently justify itself against the
/// personal dictionary before it survives. Everything else reverts to the original — a
/// leftover transcription error is strictly preferred over a confident wrong "fix".
public enum CorrectionGuard {
    /// Word-level diff between `original` and `proposal`. A changed word span is only kept
    /// when the proposed text for that span — punctuation-trimmed, case- and
    /// diacritic-folded — exactly matches one entry in `terms`. Anything else (rewordings,
    /// added or removed sentences, near-misses) falls back to the original span.
    public static func apply(
        original: String,
        proposal: String,
        terms: [String],
        aliases: VocabularyAliases = VocabularyAliases()
    ) -> String {
        let aliasTargets = aliases.termsByAlias()
        let originalTokens = tokenize(original)
        guard !originalTokens.isEmpty, !terms.isEmpty else { return original }

        let proposalTokens = tokenize(proposal)
        // Normalized form to the term's canonical spelling. The model writes what it likes
        // ("Sellerboard"), the dictionary decides how the term is spelled in the file.
        var canonical: [String: String] = [:]
        for term in terms where canonical[normalize(term)] == nil {
            canonical[normalize(term)] = term
        }

        var result: [String] = []
        for span in group(rawDiff(originalTokens, proposalTokens)) {
            switch span {
            case .equal(let words):
                result.append(contentsOf: words)
            case .replace(let originalWords, let proposedWords):
                let proposed = proposedWords.joined(separator: " ")
                let replaced = originalWords.joined(separator: " ")
                let declaredAlias = aliasTargets[VocabularyAliases.fold(replaced)]
                if let term = canonical[normalize(proposed)],
                   declaredAlias.map({ isExactly($0, term: term) }) == true
                       || soundsLike(replaced, term: term, amongst: terms) {
                    // Keep whatever punctuation the model's span carried around the term.
                    result.append(contentsOf: reSpell(proposed, as: term).split(separator: " ").map(String.init))
                } else {
                    result.append(contentsOf: originalWords)
                }
            case .delete(let originalWords):
                // The model dropped words; never delete from the original transcript.
                result.append(contentsOf: originalWords)
            case .insert:
                // The model added words the speaker never said; never insert them.
                break
            }
        }
        return result.joined(separator: " ")
    }

    // MARK: - Tokenization & normalization

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// How far a term may be from what the recogniser actually produced, as edit distance
    /// relative to the longer string.
    ///
    /// Measured on real material, genuine repairs cluster low and coincidences start well above:
    /// "Bitwarten"/"Bitwarden" 0.11, "das Boat"/"Dashboard"
    /// 0.33, "Sella Boat"/"sellerboard" 0.36 — against "laufen"/"Claude" 0.50, "auch"/"ACOS" 0.75.
    /// At 0.5 a four letter term like ACOS would swallow ordinary German words.
    static let maxDistanceRatio = 0.4
    /// How much closer a competing term has to be before the proposal counts as the wrong pick.
    static let decisiveMargin = 0.15

    /// Is this span already the term, spelling aside?
    static func isExactly(_ span: String, term: String) -> Bool {
        phoneticKey(span) == phoneticKey(term)
    }

    /// Does `term` plausibly sound like what the recogniser wrote?
    ///
    /// The model picks terms by context and gets the wrong one from the list often enough to
    /// matter: it turned "Amazon das Boat" into "Amazon sellerboard" in two of three runs. Being
    /// a dictionary term is therefore not sufficient — it also has to resemble the words it
    /// replaces, and no other term may fit those words noticeably better.
    static func soundsLike(_ span: String, term: String, amongst terms: [String]) -> Bool {
        let source = phoneticKey(span)
        guard !source.isEmpty, !phoneticKey(term).isEmpty else { return false }

        let best = distance(from: source, to: term)
        guard best <= maxDistanceRatio else { return false }

        for other in terms where phoneticKey(other) != phoneticKey(term) {
            if distance(from: source, to: other) + decisiveMargin < best { return false }
        }
        return true
    }

    private static func distance(from source: String, to term: String) -> Double {
        distanceRatio(source, phoneticKey(term))
    }

    /// Letters and digits only, lowercased, diacritics folded, spaces dropped — "das Boat" and
    /// "Dashboard" only look close once the space is gone.
    private static func phoneticKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func distanceRatio(_ lhs: String, _ rhs: String) -> Double {
        let longer = max(lhs.count, rhs.count)
        guard longer > 0 else { return 0 }
        // Length alone already exceeds the budget, so the full matrix cannot beat it. Cheap, and
        // it skips most of the work when every word is compared against every term.
        let lengthGap = abs(lhs.count - rhs.count)
        if Double(lengthGap) / Double(longer) > maxDistanceRatio { return 1 }
        return Double(editDistance(Array(lhs), Array(rhs))) / Double(longer)
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// Replaces the term inside a span with its dictionary spelling, keeping leading and
    /// trailing punctuation such as a comma or a closing bracket.
    private static func reSpell(_ span: String, as term: String) -> String {
        let leading = span.prefix { !$0.isLetter && !$0.isNumber }
        let trailing = span.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed()
        return String(leading) + term + String(trailing)
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .alphanumerics.inverted)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Word-level diff (LCS)

    private enum RawOp {
        case match(String)
        case delete(String)
        case insert(String)
    }

    private enum Span {
        case equal([String])
        case replace([String], [String])
        case delete([String])
        case insert([String])
    }

    /// Classic LCS backtrack over word tokens. O(n·m), sentence-sized inputs only.
    private static func rawDiff(_ a: [String], _ b: [String]) -> [RawOp] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else {
            return a.map { .delete($0) } + b.map { .insert($0) }
        }

        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var ops: [RawOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.match(a[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.delete(a[i]))
                i += 1
            } else {
                ops.append(.insert(b[j]))
                j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }

    /// Groups atomic diff ops into spans, pairing adjacent deletions and insertions into a
    /// single `replace` so a multi-word original phrase can be judged against a single term.
    private static func group(_ ops: [RawOp]) -> [Span] {
        var spans: [Span] = []
        var originalBuffer: [String] = []
        var proposedBuffer: [String] = []

        func flush() {
            defer { originalBuffer = []; proposedBuffer = [] }
            switch (originalBuffer.isEmpty, proposedBuffer.isEmpty) {
            case (true, true): return
            case (false, false): spans.append(.replace(originalBuffer, proposedBuffer))
            case (false, true): spans.append(.delete(originalBuffer))
            case (true, false): spans.append(.insert(proposedBuffer))
            }
        }

        for op in ops {
            switch op {
            case .match(let word):
                flush()
                spans.append(.equal([word]))
            case .delete(let word):
                originalBuffer.append(word)
            case .insert(let word):
                proposedBuffer.append(word)
            }
        }
        flush()
        return spans
    }
}
