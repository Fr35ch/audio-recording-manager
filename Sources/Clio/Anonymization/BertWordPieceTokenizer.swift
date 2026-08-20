import Foundation

/// A single BERT WordPiece token with its UTF-16 character offset range in
/// the original (untokenized) input text. `nil` offsets mark special tokens
/// ([CLS], [SEP]) that don't correspond to real input characters.
struct BertToken {
    let id: Int
    let isContinuation: Bool  // "##" piece
    let start: Int?
    let end: Int?
}

/// Minimal WordPiece tokenizer matching the `NbAiLab/nb-bert-base-ner`
/// tokenizer config: cased (`do_lower_case = false`), no accent stripping,
/// BERT-style basic tokenization (whitespace + punctuation splitting) then
/// greedy longest-match-first WordPiece subword splitting.
///
/// Because the model is cased and does not strip accents, every basic token
/// is a verbatim, contiguous substring of the original text — this lets us
/// compute exact character offsets for every subword by simple left-to-right
/// cumulative counting within each basic token's span, without any fuzzy
/// re-alignment against the original string.
final class BertWordPieceTokenizer {
    private let vocab: [String: Int]
    private let unkToken = "[UNK]"
    private let clsToken = "[CLS]"
    private let sepToken = "[SEP]"
    private let maxInputCharsPerWord = 200

    let clsTokenId: Int
    let sepTokenId: Int
    let unkTokenId: Int

    init?(vocabURL: URL) {
        guard let contents = try? String(contentsOf: vocabURL, encoding: .utf8) else { return nil }
        var v: [String: Int] = [:]
        var idx = 0
        contents.enumerateLines { line, _ in
            v[line] = idx
            idx += 1
        }
        self.vocab = v
        guard let cls = v[clsToken], let sep = v[sepToken], let unk = v[unkToken] else { return nil }
        self.clsTokenId = cls
        self.sepTokenId = sep
        self.unkTokenId = unk
    }

    /// Splits text on whitespace, then further splits each chunk at
    /// punctuation boundaries (each punctuation character becomes its own
    /// token) — matches HF `BasicTokenizer` behavior with
    /// `do_lower_case=False, strip_accents=False`.
    private func basicTokenize(_ text: String) -> [(token: String, start: Int, end: Int)] {
        let ns = text as NSString
        var result: [(String, Int, Int)] = []
        var i = 0
        let length = ns.length

        func isWhitespace(_ c: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(c) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        func isPunctuation(_ c: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(c) else { return false }
            // BERT treats ASCII punctuation and Unicode punctuation/symbol
            // categories as punctuation for splitting purposes.
            return CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }

        while i < length {
            while i < length && isWhitespace(ns.character(at: i)) { i += 1 }
            if i >= length { break }
            let wordStart = i
            if isPunctuation(ns.character(at: i)) {
                result.append((ns.substring(with: NSRange(location: i, length: 1)), i, i + 1))
                i += 1
                continue
            }
            while i < length && !isWhitespace(ns.character(at: i)) && !isPunctuation(ns.character(at: i)) {
                i += 1
            }
            result.append((ns.substring(with: NSRange(location: wordStart, length: i - wordStart)), wordStart, i))
        }
        return result
    }

    /// Greedy longest-match-first WordPiece split of a single basic token,
    /// returning `(pieceText-without-##-prefix, start, end, isContinuation)`.
    private func wordpieceTokenize(_ token: String, start: Int, end: Int) -> [(text: String, start: Int, end: Int, isContinuation: Bool)] {
        let chars = Array(token.utf16)
        guard chars.count <= maxInputCharsPerWord else {
            return [(unkToken, start, end, false)]
        }

        var pieces: [(String, Int, Int, Bool)] = []
        var cursor = 0
        var isBad = false

        while cursor < chars.count {
            var end2 = chars.count
            var curSubstr: String? = nil
            var isCont = cursor > 0

            while cursor < end2 {
                var substr = String(utf16CodeUnits: Array(chars[cursor..<end2]), count: end2 - cursor)
                if isCont { substr = "##" + substr }
                if vocab[substr] != nil {
                    curSubstr = substr
                    break
                }
                end2 -= 1
            }
            if curSubstr == nil {
                isBad = true
                break
            }
            let pieceStart = start + cursor
            let pieceEnd = start + end2
            pieces.append((curSubstr!, pieceStart, pieceEnd, isCont))
            cursor = end2
            isCont = true
        }

        if isBad {
            return [(unkToken, start, end, false)]
        }
        return pieces
    }

    /// Tokenizes `text` into WordPiece tokens with [CLS]/[SEP] wrapping,
    /// truncated to `maxTokens` total (including specials).
    func tokenize(_ text: String, maxTokens: Int) -> [BertToken] {
        var tokens: [BertToken] = [BertToken(id: clsTokenId, isContinuation: false, start: nil, end: nil)]

        outer: for (basic, bStart, bEnd) in basicTokenize(text) {
            for piece in wordpieceTokenize(basic, start: bStart, end: bEnd) {
                if tokens.count >= maxTokens - 1 { break outer }  // leave room for [SEP]
                let id = vocab[piece.text] ?? unkTokenId
                tokens.append(BertToken(id: id, isContinuation: piece.isContinuation, start: piece.start, end: piece.end))
            }
        }

        tokens.append(BertToken(id: sepTokenId, isContinuation: false, start: nil, end: nil))
        return tokens
    }

    /// Returns just the subword token count (no specials) for a text —
    /// used by the chunker to decide where to split without needing full
    /// offset tracking.
    func countSubwordTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        for (basic, bStart, bEnd) in basicTokenize(text) {
            count += wordpieceTokenize(basic, start: bStart, end: bEnd).count
        }
        return count
    }
}
