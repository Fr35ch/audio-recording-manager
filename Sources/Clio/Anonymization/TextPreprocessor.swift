import Foundation

/// Text pre-processor for the native anonymization pipeline.
///
/// Normalizes input text before it reaches any detection layer. Currently
/// handles ALL-CAPS words in speech transcripts and similar informal input.
/// Direct port of `no_anonymizer/preprocessor.py`.
enum TextPreprocessor {
    private static let wordRegex: NSRegularExpression = {
        // Maximal run of Unicode letter characters (no digits, no
        // punctuation) — mirrors Python's `[^\W\d_]+`.
        try! NSRegularExpression(pattern: "\\p{L}+", options: [])
    }()

    /// Normalize ALL-CAPS words of 4+ characters to Title Case.
    ///
    /// Rules:
    /// - Word is ALL-CAPS and len >= 4  → Title Case  (KONTRASTER → Kontraster)
    /// - Word is ALL-CAPS and len <= 3  → unchanged   (NAV, EU, IT → unchanged)
    /// - Word has mixed casing          → unchanged   (iPhone → unchanged)
    ///
    /// All other characters (digits, punctuation, whitespace) are preserved
    /// exactly, so character offsets remain valid for downstream layers.
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = wordRegex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(ns.length)
        var cursor = 0

        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let word = ns.substring(with: range)
            if word.count >= 4 && word == word.uppercased() && word != word.lowercased() {
                let first = String(word.prefix(1))
                let rest = String(word.dropFirst()).lowercased()
                result += first + rest
            } else {
                result += word
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }
}
