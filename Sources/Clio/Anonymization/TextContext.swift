import Foundation

/// Shared text-context helpers used across detection and filtering layers.
///
/// Direct port of `no_anonymizer/text_context.py`. Works on UTF-16 offsets
/// (`NSString` semantics) to stay consistent with `NSRegularExpression`
/// throughout the rest of the native anonymization pipeline.
enum TextContext {
    /// Splits at end-of-sentence punctuation followed by whitespace and a
    /// capital letter. Tolerant of "..." and "!?". Used by the BERT chunker
    /// and the ambiguity filter for sentence-start detection.
    static let sentenceBoundaryRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "(?<=[.!?])\\s+(?=[A-ZÆØÅ])", options: [])
    }()

    /// Characters that legitimately open a new sentence even though they are
    /// not letters: opening quote marks (Norwegian «, English ") and
    /// bullet/list-item prefixes. Used by `isSentenceStart`.
    private static let sentenceOpenerChars = Set("«\"'„\u{201C}")

    /// Return true if `pos` (UTF-16 offset) in `text` is at the start of a sentence.
    ///
    /// A position is a sentence start if, after walking backward over
    /// whitespace and any opening punctuation (quotes, list-item prefixes),
    /// we land at the start of the text, immediately after
    /// sentence-terminating punctuation, or after a paragraph break.
    static func isSentenceStart(_ text: String, pos: Int) -> Bool {
        guard pos > 0 else { return true }
        let ns = text as NSString
        var i = pos - 1

        func char(at idx: Int) -> unichar { ns.character(at: idx) }
        func isSpace(_ c: unichar) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(c)!)
        }
        func isDigit(_ c: unichar) -> Bool {
            CharacterSet.decimalDigits.contains(UnicodeScalar(c)!)
        }

        // Skip over opening punctuation directly before the position (e.g. "«Per").
        while i >= 0, let scalar = Unicode.Scalar(char(at: i)), sentenceOpenerChars.contains(Character(scalar)) {
            i -= 1
        }
        // Skip whitespace.
        while i >= 0 && isSpace(char(at: i)) {
            if char(at: i) == 0x0A /* \n */ && i > 0 && char(at: i - 1) == 0x0A {
                return true
            }
            i -= 1
        }
        if i < 0 { return true }

        // If we hit a list-item prefix character at the start of a line,
        // that's also a sentence start.
        let bulletChars: Set<unichar> = [0x2D /* - */, 0x2A /* * */, 0x2022 /* • */]
        if bulletChars.contains(char(at: i)) {
            var j = i - 1
            while j >= 0 && char(at: j) == 0x20 { j -= 1 }
            if j < 0 || char(at: j) == 0x0A { return true }
        }
        // A digit followed by a period ("1. ") is also a list-item start.
        if char(at: i) == 0x2E /* . */ {
            var j = i - 1
            while j >= 0 && isDigit(char(at: j)) { j -= 1 }
            if j < i - 1 {
                var k = j
                while k >= 0 && char(at: k) == 0x20 { k -= 1 }
                if k < 0 || char(at: k) == 0x0A { return true }
            }
            // Plain end-of-sentence period.
            return true
        }
        return char(at: i) == 0x21 /* ! */ || char(at: i) == 0x3F /* ? */
    }
}
