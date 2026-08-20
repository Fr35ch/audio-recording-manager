import Foundation

/// Strictness levels for ambiguous first-name filtering. Direct port of
/// Python's `Strictness = Literal["strict", "balanced", "loose"]`.
enum NameStrictness: String {
    case strict
    case balanced
    case loose
}

/// Context-aware filter for ambiguous Norwegian first names.
///
/// Direct port of `no_anonymizer/layers/ambiguity.py`. Several Norwegian
/// first names are also common nouns or function words — "Vår" (spring),
/// "Jo" (yes), "Dag" (day), "Per" (per), "Mai" (May), "Bjørn" (bear), "Tor"
/// (thunder), "Liv" (life), "Hans" (his). The SSB names layer catches them
/// all token-for-token; BERT NER often does too. This filter runs after
/// span merging and drops spans that, by their surrounding context, are
/// almost certainly the common-word reading. See the Python module
/// docstring for the full rule table.
enum AmbiguityFilter {
    /// Threshold above which BERT NER's confidence overrides the ambiguity filter.
    private static let bertOverrideThreshold = 0.95

    private static let namePrecursors: Set<String> = [
        "hr", "hr.", "fru", "frk", "frk.", "fr", "fr.", "navnet", "heter",
        "intervjuet", "snakket", "snakka", "hilste", "kalt", "kalte", "kjent",
        "møtte", "mette", "møter", "hei", "hallo", "kjære",
    ]

    private static let reportingVerbs: Set<String> = [
        "sa", "sier", "sa:", "spurte", "svarte", "mente", "fortalte", "ropte",
        "hvisket", "lo", "spør", "sier:", "svarer",
    ]

    private static let tokenCharSet: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_-")
        // À-ÿ (Latin-1 Supplement letters) + explicit Norwegian diacritics,
        // matching Python's `[\wÅÆØåæøÀ-ÿ\-]` token class.
        let range = UnicodeScalar("À")...UnicodeScalar("ÿ")
        set.insert(charactersIn: range)
        return set
    }()

    private static func isTokenChar(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return tokenCharSet.contains(scalar)
    }

    /// Load the ambiguous-names resource file into a case-folded `Set<String>`.
    /// Returns an empty set (degrade to strict behavior on every name) if the
    /// file is missing.
    static let ambiguousNames: Set<String> = {
        guard let url = Bundle.main.url(forResource: "ambiguous_names", withExtension: "txt"),
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
    }()

    private static func wasOriginallyCapitalized(_ ns: NSString, pos: Int) -> Bool {
        guard pos >= 0 && pos < ns.length else { return false }
        let c = ns.character(at: pos)
        guard let scalar = Unicode.Scalar(c) else { return false }
        return Character(scalar).isUppercase
    }

    /// Returns `(token, startIndex)` for the token ending before `end`, or
    /// `nil` if no token precedes it or a sentence break intervenes.
    private static func prevToken(_ ns: NSString, end: Int) -> (token: String, start: Int)? {
        var i = end - 1
        while i >= 0 && !isTokenChar(ns.character(at: i)) {
            let c = ns.character(at: i)
            if c == 0x2E || c == 0x21 || c == 0x3F { return nil }  // . ! ?
            i -= 1
        }
        if i < 0 { return nil }
        let endIdx = i + 1
        while i >= 0 && isTokenChar(ns.character(at: i)) { i -= 1 }
        let start = i + 1
        return (ns.substring(with: NSRange(location: start, length: endIdx - start)), start)
    }

    /// Returns `(token, startIndex)` for the token after `start`, or `nil` if
    /// no token follows or a sentence break intervenes.
    private static func nextToken(_ ns: NSString, start: Int) -> (token: String, start: Int)? {
        var i = start
        while i < ns.length && !isTokenChar(ns.character(at: i)) {
            let c = ns.character(at: i)
            if c == 0x2E || c == 0x21 || c == 0x3F { return nil }
            i += 1
        }
        if i >= ns.length { return nil }
        let begin = i
        while i < ns.length && isTokenChar(ns.character(at: i)) { i += 1 }
        return (ns.substring(with: NSRange(location: begin, length: i - begin)), begin)
    }

    private static func stripTrailingPunct(_ s: String) -> String {
        var result = s
        while let last = result.last, ".,:;".contains(last) {
            result.removeLast()
        }
        return result
    }

    private static func hasNamePrecursor(_ ns: NSString, spanStart: Int) -> Bool {
        guard let (token, _) = prevToken(ns, end: spanStart) else { return false }
        let cf = token.lowercased()
        return namePrecursors.contains(stripTrailingPunct(cf)) || namePrecursors.contains(cf)
    }

    private static func hasReportingPostcursor(_ ns: NSString, spanEnd: Int) -> Bool {
        guard let (token, _) = nextToken(ns, start: spanEnd) else { return false }
        let cf = token.lowercased()
        return reportingVerbs.contains(stripTrailingPunct(cf)) || reportingVerbs.contains(cf)
    }

    private static func hasCapitalizedNameNeighbor(
        _ ns: NSString, spanStart: Int, spanEnd: Int, names: Set<String>, ambiguous: Set<String>
    ) -> Bool {
        guard !names.isEmpty else { return false }
        for tokInfo in [prevToken(ns, end: spanStart), nextToken(ns, start: spanEnd)] {
            guard let (token, idx) = tokInfo, !token.isEmpty else { continue }
            guard wasOriginallyCapitalized(ns, pos: idx) else { continue }
            let cf = token.lowercased()
            if ambiguous.contains(cf) { continue }
            if names.contains(cf) { return true }
        }
        return false
    }

    private static func hasLowercaseNameNeighbor(
        _ ns: NSString, spanStart: Int, spanEnd: Int, names: Set<String>, ambiguous: Set<String>
    ) -> Bool {
        guard !names.isEmpty else { return false }
        for tokInfo in [prevToken(ns, end: spanStart), nextToken(ns, start: spanEnd)] {
            guard let (token, _) = tokInfo, !token.isEmpty else { continue }
            let cf = token.lowercased()
            if ambiguous.contains(cf) { continue }
            if names.contains(cf) { return true }
        }
        return false
    }

    private static func shouldKeep(
        _ span: PIISpan, ns: NSString, names: Set<String>, ambiguous: Set<String>, strictness: NameStrictness
    ) -> Bool {
        // Rule 3: high-confidence BERT NER overrides everything.
        if let score = span.score, score >= bertOverrideThreshold {
            return true
        }

        let capitalized = wasOriginallyCapitalized(ns, pos: span.position)

        // Lowercase fallback: keep the span if it looks like part of a
        // multi-word name in a sloppy lowercase transcript.
        if !capitalized && hasLowercaseNameNeighbor(ns, spanStart: span.position, spanEnd: span.end, names: names, ambiguous: ambiguous) {
            return true
        }

        // Rule 1: not capitalized in source → drop.
        if !capitalized { return false }

        let sentenceStart = TextContext.isSentenceStart(ns as String, pos: span.position)

        let hasSupport =
            hasCapitalizedNameNeighbor(ns, spanStart: span.position, spanEnd: span.end, names: names, ambiguous: ambiguous)
            || hasNamePrecursor(ns, spanStart: span.position)
            || hasReportingPostcursor(ns, spanEnd: span.end)

        if strictness == .loose {
            return hasSupport
        }

        // balanced mode:
        if sentenceStart {
            return hasSupport  // Rule 2
        }
        return true  // Rule 4: sentence-mid capitalization is sufficient
    }

    /// Return `spans` with ambiguous-name false positives removed.
    ///
    /// - Parameters:
    ///   - spans: NAVN/STED/etc. spans produced by upstream layers and merged.
    ///   - rawText: The original (post-normalization) input text.
    ///   - ambiguousNames: Case-folded set of names needing contextual support.
    ///   - names: Case-folded set of all SSB names.
    ///   - strictness: `.strict` skips filtering; `.balanced` (default)
    ///     applies the rule table; `.loose` requires strong support for
    ///     every ambiguous span.
    static func filterAmbiguous(
        _ spans: [PIISpan], rawText: String, ambiguousNames: Set<String>, names: Set<String>,
        strictness: NameStrictness = .balanced
    ) -> [PIISpan] {
        if strictness == .strict || ambiguousNames.isEmpty {
            return spans
        }

        let ns = rawText as NSString
        var surviving: [PIISpan] = []
        for span in spans {
            guard span.category == "NAVN" else {
                surviving.append(span)
                continue
            }
            let surface = ns.substring(with: NSRange(location: span.position, length: span.length))
            guard ambiguousNames.contains(surface.lowercased()) else {
                surviving.append(span)
                continue
            }
            if shouldKeep(span, ns: ns, names: names, ambiguous: ambiguousNames, strictness: strictness) {
                surviving.append(span)
            }
        }
        return surviving
    }
}
