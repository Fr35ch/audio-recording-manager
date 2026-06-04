// HomographDisambiguator.swift
// Clio
//
// Post-processes an `AnonymizationResult` by asking the local Ollama
// model to context-disambiguate redactions on known Norwegian
// homographs (Per, Slette, Vår, Mai, …). The upstream BERT NER cannot
// reason about full-sentence semantics, so it over-redacts these
// tokens — see `tests/fixtures/anonymizer_stress_test.md` and
// `docs/no_anonymizer_v2_implementasjon.md` for the failure mode.
//
// This is a pragmatic stopgap until upstream `no-anonymizer` v2's
// handcrafted evidence-based rules land. The hybrid approach (BERT
// first, LLM check on ambiguous tokens) trades a few seconds of
// runtime for ~80–90% reduction in homograph false positives.
//
// Architecture:
//   1. For each NAVN redaction whose original span (case-insensitive)
//      matches `norwegianHomographs`, send ±30 chars of context to
//      Ollama with a strict JA/NEI prompt.
//   2. Drop redactions where Ollama replies NEI ("not a name in this
//      context").
//   3. Rebuild the anonymized text from the surviving redactions.
//   4. Gracefully no-op if Ollama is unreachable (privacy-safe default:
//      keep the original BERT decision — never *add* redactions, never
//      *drop* them silently when uncertain).
//
// No data leaves the machine — Ollama runs at localhost:11434.

import Foundation

enum HomographDisambiguator {

    /// Norwegian tokens that are both common surnames/first-names AND
    /// common words (verb / preposition / month / animal / season /
    /// musical term). Matched case-insensitively against
    /// `redaction.original` (the source-text span).
    ///
    /// Keep this list tight: every entry costs one LLM call per
    /// occurrence in the transcript. Pure names (Mona, Linn, Frida)
    /// don't belong here — they're almost never common words.
    static let norwegianHomographs: Set<String> = [
        "per", "slette", "vår", "mai", "mars", "tor", "even",
        "sol", "tone", "bjørn", "vidar", "ulf",
    ]

    /// Context window (chars before + chars after the token) sent to
    /// the LLM. 30 chars each side is enough to disambiguate most
    /// real Norwegian sentences without dragging too much surrounding
    /// transcript into the prompt.
    private static let contextWindow: Int = 60

    // MARK: - Filter result

    struct FilterReport {
        var queried: Int = 0
        var kept: Int = 0      // LLM said JA — still a name → redaction preserved
        var dropped: Int = 0   // LLM said NEI — not a name in context → redaction removed
        var skipped: Int = 0   // Ollama unreachable / errored → redaction preserved
    }

    /// Filters `result` by re-classifying homograph redactions with the
    /// local LLM. Returns the (possibly modified) result and a report.
    ///
    /// Pure on the input — never mutates `result`. Falls back to
    /// returning `result` unchanged if Ollama isn't available.
    static func filter(
        result: AnonymizationResult,
        sourceText: String,
        model: String
    ) async -> (AnonymizationResult, FilterReport) {
        var report = FilterReport()

        // Identify which redactions to query. Skip everything that's
        // not a NAVN homograph in the very first pass — most
        // transcripts only have a handful of LLM-worthy candidates.
        let sourceChars = Array(sourceText)
        var queriedIndices: [Int] = []
        for (idx, r) in result.redactions.enumerated() {
            guard r.category == "NAVN" else { continue }
            let span = extractSpan(r, from: sourceChars)
            if norwegianHomographs.contains(span.lowercased()) {
                queriedIndices.append(idx)
            }
        }
        report.queried = queriedIndices.count

        guard !queriedIndices.isEmpty else {
            return (result, report)
        }

        // Probe Ollama availability before issuing N calls — saves a
        // pile of timeouts if the daemon is down.
        guard OllamaManager.shared.isRunning() else {
            report.skipped = queriedIndices.count
            return (result, report)
        }

        // Query the LLM for each candidate. Sequential — we could
        // parallelise but per-transcript counts are tiny (typically
        // 5–15) and we want predictable rate-limiting against the
        // local model.
        var droppedIndices = Set<Int>()
        for idx in queriedIndices {
            let r = result.redactions[idx]
            let span = extractSpan(r, from: sourceChars)
            let context = extractContext(around: r, in: sourceText)
            let decision = await askIsName(
                token: span, context: context, model: model)
            switch decision {
            case .notName:
                droppedIndices.insert(idx)
                report.dropped += 1
            case .name:
                report.kept += 1
            case .uncertain:
                // Privacy-safe default: preserve the redaction when the
                // LLM is unclear. Counts as `kept`.
                report.kept += 1
            }
        }

        // Rebuild the result with the surviving redactions and
        // reassembled anonymized text. Mirrors the algorithm used by
        // `AnonymizationResult.applying(exceptions:to:)`.
        let survivors = result.redactions.enumerated().compactMap {
            droppedIndices.contains($0.offset) ? nil : $0.element
        }
        let rebuiltText = rebuildAnonymizedText(
            from: sourceText, redactions: survivors)
        let newStats = recomputeStats(survivors)

        let filtered = AnonymizationResult(
            anonymizedText: rebuiltText,
            redactions: survivors,
            stats: newStats,
            processingTimeMs: result.processingTimeMs,
            version: result.version,
            flaggedForReview: result.flaggedForReview,
            statistics: result.statistics,
            auditLogPath: result.auditLogPath
        )
        return (filtered, report)
    }

    // MARK: - LLM call

    private enum NameDecision { case name, notName, uncertain }

    private static func askIsName(
        token: String, context: String, model: String
    ) async -> NameDecision {
        let prompt = """
        Du er en norsk språkmodell. I setningen under, brukes ordet "\(token)" som et personnavn?

        Setning: "\(context)"

        Svar bare JA eller NEI. JA hvis ordet refererer til et menneske ved navn. NEI hvis det brukes som måned, årstid, dyrenavn, verb, preposisjon, eller annet vanlig ord.

        Svar:
        """

        guard let body = try? JSONEncoder().encode(
            OllamaGenerateRequest(model: model, prompt: prompt, stream: false))
        else { return .uncertain }

        var request = URLRequest(
            url: URL(string: "http://localhost:11434/api/generate")!,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let resp = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            let answer = resp.response
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if answer.contains("NEI") { return .notName }
            if answer.contains("JA")  { return .name }
            return .uncertain
        } catch {
            return .uncertain
        }
    }

    // MARK: - Text helpers

    private static func extractSpan(
        _ r: Redaction, from sourceChars: [Character]
    ) -> String {
        let start = max(0, r.position)
        let end = min(sourceChars.count, r.position + r.length)
        guard start < end else { return "" }
        return String(sourceChars[start..<end])
    }

    private static func extractContext(
        around r: Redaction, in source: String
    ) -> String {
        let chars = Array(source)
        let s = max(0, r.position - contextWindow / 2)
        let e = min(chars.count, r.position + r.length + contextWindow / 2)
        return String(chars[s..<e])
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func rebuildAnonymizedText(
        from source: String, redactions: [Redaction]
    ) -> String {
        let chars = Array(source)
        var out = ""
        var cursor = 0
        for r in redactions.sorted(by: { $0.position < $1.position }) {
            let start = max(0, r.position)
            let end = min(chars.count, r.position + r.length)
            if cursor < start {
                out.append(contentsOf: chars[cursor..<start])
            }
            out.append(r.replacement)
            cursor = end
        }
        if cursor < chars.count {
            out.append(contentsOf: chars[cursor..<chars.count])
        }
        return out
    }

    private static func recomputeStats(_ redactions: [Redaction]) -> [String: Int] {
        var stats: [String: Int] = [:]
        for r in redactions {
            stats[r.category, default: 0] += 1
        }
        return stats
    }
}

// MARK: - Ollama wire types (private to this file)

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}
