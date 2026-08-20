import Foundation

/// Kartverket SSR place name-based detection of Norwegian cities and towns.
///
/// Direct port of `no_anonymizer/layers/steder.py`. Loads place names from a
/// bundled resource file and scans the input text token by token. Any
/// capitalized token matching a known place name is tagged as `[STED]`.
///
/// Matching rules:
///   - Case-sensitive: "Bergen" is redacted, "bergen" is not. This avoids
///     false positives for common Norwegian words that share spelling with
///     place names (e.g. "sand", "nes", "dal").
///   - Single-token matching only (multi-word names like "Os i Hordaland"
///     are not matched — rely on BERT NER for those).
enum StederDetector {
    private static let tokenRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "[\\wÅÆØåæøÀ-ÿ\\-]+", options: [])
    }()

    /// Place names (original casing preserved), loaded once from the
    /// bundled resource file.
    static let places: Set<String> = {
        guard let url = Bundle.main.url(forResource: "kartverket_steder", withExtension: "txt"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        var set = Set<String>()
        contents.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            set.insert(trimmed)
        }
        return set
    }()

    /// Return `[STED]` spans for all place name tokens found in `text`.
    static func detect(_ text: String, places: Set<String> = StederDetector.places) -> [PIISpan] {
        guard !places.isEmpty else { return [] }

        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var spans: [PIISpan] = []

        for match in tokenRegex.matches(in: text, options: [], range: fullRange) {
            let token = ns.substring(with: match.range)
            if places.contains(token) {
                spans.append(PIISpan(position: match.range.location, length: match.range.length,
                                      category: "STED", replacement: "[STED]"))
            }
        }
        return spans
    }
}
