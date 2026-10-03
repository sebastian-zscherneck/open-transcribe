import Foundation

/// Pure functions turning an arbitrary title suggestion into a filesystem-safe slug.
/// Never throws — invalid input simply normalizes to `nil` so callers fall back.
public enum Slug {
    private static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    private static let minLength = 3
    private static let maxLength = 40

    /// Normalizes `raw` into `^[a-z0-9-]{3,40}$`, or `nil` if nothing usable remains.
    public static func normalize(_ raw: String) -> String? {
        let transliterated = transliterate(raw).lowercased()

        var result = ""
        var lastWasDash = false
        for scalar in transliterated.unicodeScalars {
            if allowedCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }

        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !result.isEmpty else { return nil }

        let truncated = truncateWithoutSplittingWords(result, maxLength: maxLength)
        guard truncated.count >= minLength else { return nil }
        guard truncated.range(of: "^[a-z0-9-]{3,40}$", options: .regularExpression) != nil else { return nil }
        return truncated
    }

    /// Deterministic fallback when no suggestion is usable: `meeting-{appslug}-{HHmm}`.
    public static func fallback(appName: String, at date: Date) -> String {
        let appSlug = normalize(appName) ?? "app"
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "HHmm"
        return "meeting-\(appSlug)-\(fmt.string(from: date))"
    }

    private static func transliterate(_ input: String) -> String {
        var s = input
        let map: [(String, String)] = [
            ("ä", "ae"), ("ö", "oe"), ("ü", "ue"),
            ("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue"),
            ("ß", "ss"),
        ]
        for (from, to) in map {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    /// Cuts at `maxLength`, then backs up to the last `-` so no word is cut mid-way.
    private static func truncateWithoutSplittingWords(_ s: String, maxLength: Int) -> String {
        guard s.count > maxLength else { return s }
        let prefix = String(s.prefix(maxLength))
        if let lastDash = prefix.lastIndex(of: "-") {
            return String(prefix[..<lastDash])
        }
        // No separator within the limit at all — a single overlong word, hard cut.
        return prefix
    }
}
