import Foundation

/// SSB (Statistics Norway) name list-based detection of personal names.
///
/// Direct port of `no_anonymizer/layers/ssb_names.py`. Loads first names
/// (fornavn) and last names (etternavn) from bundled resource files and
/// scans the input text token by token. Any token matching a name in the
/// lists is tagged as `[NAVN]`.
///
/// Matching rules:
///   - Case-insensitive (Norwegian case-folding via `.lowercased()`)
///   - Hyphenated names (Olav-Martin): each part is checked independently;
///     the whole hyphenated token is redacted if ANY part is a known name.
///   - Standalone first names ARE redacted (maximum GDPR coverage).
enum SSBNamesDetector {
    private static let tokenRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "[\\wÅÆØåæøÀ-ÿ\\-]+", options: [])
    }()

    // Swedish/German diacritics → nearest Norwegian equivalent, so Swedish
    // surnames (e.g. Bergström) match the Norwegian SSB list (which stores
    // the equivalent Norwegian spelling, e.g. Bergstrøm).
    private static let nordicNormMap: [Character: Character] = [
        "ä": "æ", "ö": "ø", "Ä": "Æ", "Ö": "Ø",
    ]

    private static func nordicNormalize(_ s: String) -> String {
        String(s.map { nordicNormMap[$0] ?? $0 })
    }

    /// Load a name list resource file (one name per line, `#`-comments allowed)
    /// into a case-folded `Set<String>`.
    private static func loadNameSet(resource: String) -> Set<String> {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        var set = Set<String>()
        contents.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            set.insert(trimmed.lowercased())
        }
        return set
    }

    /// Combined set of case-folded known Norwegian first + last names.
    /// Loaded once and cached for the app's lifetime.
    static let names: Set<String> = {
        loadNameSet(resource: "ssb_fornavn").union(loadNameSet(resource: "ssb_etternavn"))
    }()

    private static func isNameToken(_ token: String, names: Set<String>) -> Bool {
        let cf = token.lowercased()
        if names.contains(cf) || names.contains(nordicNormalize(cf)) {
            return true
        }
        let parts = token.split(separator: "-", omittingEmptySubsequences: true)
        if parts.count > 1 {
            return parts.contains { part in
                let pcf = part.lowercased()
                return names.contains(pcf) || names.contains(nordicNormalize(pcf))
            }
        }
        return false
    }

    /// Return `[NAVN]` spans for all name tokens found in `text`.
    static func detect(_ text: String, names: Set<String> = SSBNamesDetector.names) -> [PIISpan] {
        guard !names.isEmpty else { return [] }

        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var spans: [PIISpan] = []

        for match in tokenRegex.matches(in: text, options: [], range: fullRange) {
            let token = ns.substring(with: match.range)
            if isNameToken(token, names: names) {
                spans.append(PIISpan(position: match.range.location, length: match.range.length,
                                      category: "NAVN", replacement: "[NAVN]"))
            }
        }
        return spans
    }
}
