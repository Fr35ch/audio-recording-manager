import Foundation

/// Regex-based detection of structured Norwegian PII.
///
/// Direct port of `no_anonymizer/layers/regex_patterns.py`. Detects:
///   - Phone numbers (Norwegian formats)
///   - Email addresses
///   - Fødselsnummer (birth number, first digit 0-3)
///   - D-nummer (temporary ID, first digit 4-7 due to day+40 offset)
///   - Postboks (P.O. box addresses, e.g. "Postboks 1234")
///
/// Design note — no checksum validation: fødselsnummer/d-nummer have a
/// two-digit checksum embedded in the last two digits. We deliberately do
/// NOT validate the checksum here. For GDPR purposes it is safer to
/// over-redact (false positive) than to under-redact (false negative).
enum RegexPatternDetector {
    // `[0-9]` used instead of `\d` throughout to match Python's `re.ASCII`
    // flag on these patterns (ASCII-only digit matching).

    private static let phoneRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern:
                "(?<![0-9])(?:"
                + "(?:\\+47|00[\\s\\-]?47)[\\s\\-]?"
                + "(?:[0-9]{2}[\\s\\-]?[0-9]{2}[\\s\\-]?[0-9]{2}[\\s\\-]?[0-9]{2}"
                + "|[0-9]{3}[\\s\\-]?[0-9]{2}[\\s\\-]?[0-9]{3})"
                + "|"
                + "[2-9](?:[0-9]{7}|[0-9]{2}[ \\-][0-9]{2}[ \\-][0-9]{3})"
                + ")(?![0-9])",
            options: [])
    }()

    private static let emailRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "[a-zA-Z0-9._%+\\-åæøÅÆØ]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}",
            options: [])
    }()

    private static let fnrRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "(?<![0-9])[0-3][0-9]{4}[0-9][\\s]?[0-9]{5}(?![0-9])",
            options: [])
    }()

    private static let dNummerRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "(?<![0-9])[4-7][0-9]{4}[0-9][\\s]?[0-9]{5}(?![0-9])",
            options: [])
    }()

    private static let postboksRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\bpostboks\\s+[0-9]+\\b", options: [.caseInsensitive])
    }()

    /// Return all regex-detected PII spans in `text`, sorted by position.
    static func detect(_ text: String) -> [PIISpan] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var spans: [PIISpan] = []

        for match in emailRegex.matches(in: text, options: [], range: fullRange) {
            spans.append(PIISpan(position: match.range.location, length: match.range.length,
                                  category: "EPOST", replacement: "[EPOST]"))
        }
        for match in phoneRegex.matches(in: text, options: [], range: fullRange) {
            spans.append(PIISpan(position: match.range.location, length: match.range.length,
                                  category: "TELEFON", replacement: "[TELEFON]"))
        }
        for match in fnrRegex.matches(in: text, options: [], range: fullRange) {
            spans.append(PIISpan(position: match.range.location, length: match.range.length,
                                  category: "FØDSELSNUMMER", replacement: "[FØDSELSNUMMER]"))
        }
        for match in dNummerRegex.matches(in: text, options: [], range: fullRange) {
            spans.append(PIISpan(position: match.range.location, length: match.range.length,
                                  category: "D-NUMMER", replacement: "[D-NUMMER]"))
        }
        for match in postboksRegex.matches(in: text, options: [], range: fullRange) {
            spans.append(PIISpan(position: match.range.location, length: match.range.length,
                                  category: "ADRESSE", replacement: "[ADRESSE]"))
        }

        spans.sort { $0.position < $1.position }
        return spans
    }
}
