import Foundation

/// Orchestrates all detection layers and produces an `AnonymizationResult`.
///
/// Direct port of `no_anonymizer/anonymizer.py`'s `anonymize()` pipeline:
///   0. `TextPreprocessor.normalize()` — ALL-CAPS words (4+ chars) → Title Case
///   1. `RegexPatternDetector.detect()`  — phone, email, fnr, d-nummer, postboks
///   2. `SSBNamesDetector.detect()`      — SSB name list lookup
///   3. `StederDetector.detect()`        — Kartverket place-name gazetteer
///   4. `BertNERDetector.detect()`       — BERT NER (PER/LOC/GPE; ORG counted only)
///   5. `AddressLookupService.detect()`  — Kartverket API address verification
///   6. `mergeSpans()`                   — deduplicate and resolve overlaps
///   7. `AmbiguityFilter.filterAmbiguous()` — drop context-unsupported ambiguous names
///   8. `buildResult()`                  — substitute spans, build the result
///
/// Deliberately omits Python's `_apply_exceptions` step (`unntak.txt`) — Clio
/// already applies its own, richer, user-editable exception list
/// (`AppState.avidentExceptions` / `AvidentExceptionsView`) as a post-processing
/// step at every call site (`TranscriptEditorView`, `AvidentifiseringSheet`),
/// which fully supersedes that Python-side mechanism.
///
/// Overlap resolution priority (highest → lowest): regex > ssb/address/steder > ner.
/// Runs entirely in-process (CoreML + native Swift) — no subprocess, no
/// embedded Python, no sandbox entitlement conflict.
enum NativeAnonymizer {
    // Priority order: lower number = higher priority (matches anonymizer.py's _PRIORITY).
    private static func priority(for category: String) -> Int {
        switch category {
        case "EPOST", "TELEFON", "FØDSELSNUMMER", "D-NUMMER": return 0
        case "NAVN", "ADRESSE": return 1
        case "ORG", "STED": return 2
        default: return 3
        }
    }

    private static func mergeSpans(
        regexSpans: [PIISpan], ssbSpans: [PIISpan], nerSpans: [PIISpan],
        addressSpans: [PIISpan], stederSpans: [PIISpan]
    ) -> [PIISpan] {
        var tagged: [(priority: Int, span: PIISpan)] = []
        tagged.append(contentsOf: regexSpans.map { (0, $0) })
        tagged.append(contentsOf: ssbSpans.map { (1, $0) })
        tagged.append(contentsOf: addressSpans.map { (1, $0) })
        tagged.append(contentsOf: stederSpans.map { (1, $0) })
        tagged.append(contentsOf: nerSpans.map { (2, $0) })

        // Sort by start position, then priority ascending (higher priority
        // first), then length descending (longer match wins within tier).
        tagged.sort { a, b in
            if a.span.position != b.span.position { return a.span.position < b.span.position }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.span.length > b.span.length
        }

        var merged: [PIISpan] = []
        var lastEnd = -1
        for (_, span) in tagged {
            if span.position < lastEnd { continue }
            merged.append(span)
            lastEnd = span.end
        }
        return merged
    }

    private static func buildResult(text: String, spans: [PIISpan], orgCount: Int, elapsedMs: Double) -> AnonymizationResult {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for span in spans {
            if span.position > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: span.position - cursor))
            }
            result += span.replacement
            cursor = span.end
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }

        var stats: [String: Int] = [:]
        for span in spans { stats[span.category, default: 0] += 1 }
        if orgCount > 0 {
            stats["ORG"] = orgCount
        }

        let redactions = spans.map { span in
            Redaction(position: span.position, length: span.length, category: span.category,
                      replacement: span.replacement, decision: nil, score: span.score, bucket: nil)
        }

        return AnonymizationResult(
            anonymizedText: result, redactions: redactions, stats: stats,
            processingTimeMs: elapsedMs, version: nil, flaggedForReview: nil,
            statistics: nil, auditLogPath: nil)
    }

    /// Anonymize Norwegian free text, replacing PII with typed tokens.
    ///
    /// - Parameters:
    ///   - text: Input text to anonymize.
    ///   - useAddressLookup: If true (default), NER STED spans containing a
    ///     digit are verified against the Kartverket address register.
    ///   - nameStrictness: How aggressively to redact common Norwegian first
    ///     names that double as everyday words. See `AmbiguityFilter`.
    static func anonymize(
        text: String, useAddressLookup: Bool = true, nameStrictness: NameStrictness = .balanced
    ) -> AnonymizationResult {
        let t0 = Date()

        let normalized = TextPreprocessor.normalize(text)

        let regexSpans = RegexPatternDetector.detect(normalized)
        let ssbSpans = SSBNamesDetector.detect(normalized)
        let stederSpans = StederDetector.detect(normalized)
        let (nerSpans, orgCount) = BertNERDetector.detect(normalized)

        var addressSpans: [PIISpan] = []
        if useAddressLookup {
            let (spans, _) = AddressLookupService.detect(normalized, nerSpans: nerSpans)
            addressSpans = spans
        }

        let merged = mergeSpans(
            regexSpans: regexSpans, ssbSpans: ssbSpans, nerSpans: nerSpans,
            addressSpans: addressSpans, stederSpans: stederSpans)
        let disambiguated = AmbiguityFilter.filterAmbiguous(
            merged, rawText: normalized, ambiguousNames: AmbiguityFilter.ambiguousNames,
            names: SSBNamesDetector.names, strictness: nameStrictness)

        let elapsedMs = Date().timeIntervalSince(t0) * 1000
        let result = buildResult(text: normalized, spans: disambiguated, orgCount: orgCount, elapsedMs: elapsedMs)
        return result
    }
}
