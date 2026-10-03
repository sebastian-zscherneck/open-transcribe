import Foundation

/// Known mishearings for a term, declared by the user.
///
/// The similarity guard rejects a correction whose target is too far from what the recogniser
/// produced, which is what stops "auch" from becoming "ACOS". Real material shows the cost of
/// that rule: "n8n" is heard as "NANN", "Claude" as "Clot" or "Cloud", and both are further away
/// than any safe threshold. An alias is the user saying "this specific mishearing means this
/// specific term", so it may cross the threshold — while the model still decides in context,
/// because "Cloud" is also an ordinary word.
public struct VocabularyAliases: Codable, Sendable, Equatable {
    /// Canonical term to the mishearings that may map onto it.
    public var entries: [String: [String]]

    public init(entries: [String: [String]] = [:]) {
        self.entries = entries
    }

    public static let defaults = VocabularyAliases(entries: [
        "n8n": ["NANN", "Nann", "Enatenacht", "Enaten", "N8N", "Naten"],
        "Claude": ["Clot", "Claud", "Cloud", "Clode", "Klaud"],
        "sellerboard": ["Sella Boat", "Sellaboat", "Seller Board", "Sella Board"],
        "Dashboard": ["das Boat", "Dash Board", "Deshboard"],
        "Tracify": ["Trecify", "Tracifi", "Trackify"],
        "Shopify": ["Shopifai", "Shoppify"],
        "ACOS": ["A-Cost", "Akos", "A Cos"],
        "MCP": ["EmCePe", "M-C-P"],
    ])

    /// Terms an alias may resolve to, keyed by the misheard text, folded for comparison.
    func termsByAlias() -> [String: String] {
        var map: [String: String] = [:]
        for (term, aliases) in entries {
            for alias in aliases {
                map[VocabularyAliases.fold(alias)] = term
            }
        }
        return map
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Domain terms used to correct transcription mistakes: the user's own dictionary, wherever
/// it lives. Loading is best-effort everywhere — a missing domain, key, or corrupt file just
/// means fewer terms, never an error.
public enum PersonalDictionary {
    /// Wisper Clone's UserDefaults domain. Read-only; this codebase never writes to it.
    public static let wisperCloneSuiteName = "com.local.wisper-clone"
    public static let wisperCloneKey = "personalDictionaryTerms"
    /// Key inside `Paths.settingsFile` for terms specific to this app.
    static let extraVocabularyKey = "extraVocabulary"

    /// Loads and merges every known source, deduplicated case- and diacritic-insensitively.
    /// First occurrence wins, so Wisper Clone terms take precedence over `extraVocabulary`.
    public static func load(paths: Paths, suiteName: String = wisperCloneSuiteName) -> [String] {
        var terms = wisperCloneTerms(suiteName: suiteName)
        terms.append(contentsOf: extraVocabulary(paths: paths))
        return dedupeCaseAndDiacriticInsensitive(terms)
    }

    static func wisperCloneTerms(suiteName: String) -> [String] {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return [] }
        return defaults.stringArray(forKey: wisperCloneKey) ?? []
    }

    /// Aliases from settings, merged over the shipped defaults so the user can extend and
    /// override without restating the whole list.
    public static func loadAliases(paths: Paths) -> VocabularyAliases {
        var merged = VocabularyAliases.defaults.entries
        guard let data = try? Data(contentsOf: paths.settingsFile) else {
            return VocabularyAliases(entries: merged)
        }
        struct Wrapper: Decodable { let vocabularyAliases: [String: [String]]? }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data),
              let extra = wrapper.vocabularyAliases
        else { return VocabularyAliases(entries: merged) }

        for (term, aliases) in extra {
            merged[term, default: []].append(contentsOf: aliases)
        }
        return VocabularyAliases(entries: merged)
    }

    static func extraVocabulary(paths: Paths) -> [String] {
        guard let data = try? Data(contentsOf: paths.settingsFile) else { return [] }
        struct Extra: Decodable { let extraVocabulary: [String]? }
        guard let extra = try? JSONDecoder().decode(Extra.self, from: data) else { return [] }
        return extra.extraVocabulary ?? []
    }

    static func dedupeCaseAndDiacriticInsensitive(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if seen.insert(key).inserted {
                result.append(term)
            }
        }
        return result
    }
}
