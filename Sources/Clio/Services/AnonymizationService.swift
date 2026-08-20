import Foundation

// MARK: - Result model
//
// Mirrors the JSON returned by the `no-anonymizer` Python library.
//
// Terminology note: the UI surfaces this as "avidentifisering"
// (de-identification). The legal distinction matters — true GDPR
// anonymisation would mean the data is no longer personal data and
// cannot be re-linked. We retain the audio and a deterministic mapping
// internally, so what we ship is de-identification. Swift type names
// stay as `Anonymization*` for back-compat with audit logs and
// existing call sites; only the UI strings flip to "avidentifisering".

struct Redaction: Codable, Equatable {
    let position: Int
    let length: Int
    let category: String
    let replacement: String

    // v2 enrichment fields — optional so v1 output still decodes. v2 emits
    // these alongside every redaction so the UI can explain *why* a token
    // was redacted ("triggered by ambiguous-name bucket + identity-verb
    // context, score 0.6"). Absent on v1 output.
    let decision: String?   // "redact" | "flag" | "keep"
    let score: Double?      // final aggregated score
    let bucket: String?     // "unambiguous_name" | "ambiguous" | "protected_common" | "unknown"
}

/// A token the upstream model wasn't confident enough to auto-redact but
/// also wasn't willing to keep. v2 emits these so ARM can show them in a
/// "Til gjennomgang" UI; the researcher picks Behold / Rediger per token.
/// At export time, anything still unresolved is treated as redacted per
/// `no-anonymizer` v2 spec section 4 ("Standardatferd ved usikkerhet er
/// fortsatt redaksjon").
struct FlaggedToken: Codable, Equatable {
    let original: String
    let start: Int
    let end: Int
    let type: String          // "PER" | "LOC" | "ORG"
    let score: Double
    let bucket: String
    let contextSnippet: String
    let signalsSummary: String

    enum CodingKeys: String, CodingKey {
        case original, start, end, type, score, bucket
        case contextSnippet = "context_snippet"
        case signalsSummary = "signals_summary"
    }
}

/// Aggregate statistics from a v2 anonymization run. Mirrors the
/// `statistics` block in the v2 output JSON.
struct AnonymizationStatistics: Codable, Equatable {
    let totalCandidates: Int
    let redacted: Int
    let flagged: Int
    let kept: Int
    let byBucket: [String: Int]

    enum CodingKeys: String, CodingKey {
        case totalCandidates = "total_candidates"
        case redacted, flagged, kept
        case byBucket = "by_bucket"
    }
}

struct AnonymizationResult: Codable, Equatable {
    let anonymizedText: String
    let redactions: [Redaction]
    let stats: [String: Int]
    let processingTimeMs: Double

    // v2 additions — all optional, backwards-compatible with v1 output.
    // See `docs/no_anonymizer_v2_implementasjon.md` section 6 for the
    // full JSON contract. ARM Phase A (this file) only decodes; the
    // companion UI ("Til gjennomgang" tab in `AvidentifiseringSheet`) is
    // Phase B and not yet built.
    let version: String?
    let flaggedForReview: [FlaggedToken]?
    let statistics: AnonymizationStatistics?
    let auditLogPath: String?

    enum CodingKeys: String, CodingKey {
        case anonymizedText, redactions, stats, processingTimeMs, version, statistics
        case flaggedForReview = "flagged_for_review"
        case auditLogPath = "audit_log_path"
    }
}

extension AnonymizationResult {
    /// Apply a global exception list to a freshly-returned anonymization
    /// result. Any redaction whose original substring (looked up in
    /// `sourceText` via `position`/`length`) matches an exception is
    /// dropped and the corresponding span is restored in
    /// `anonymizedText`. Matching is case-insensitive equality on the
    /// full redacted span — the upstream NER returns discrete spans, so
    /// equality is appropriate and word-boundary checks are unnecessary.
    ///
    /// Stats are recomputed from the surviving redaction set so the UI
    /// reflects what was actually redacted, not what the model proposed.
    ///
    /// Returns a fresh `AnonymizationResult`; the input is unchanged.
    func applying(exceptions: [String], to sourceText: String) -> AnonymizationResult {
        guard !exceptions.isEmpty, !redactions.isEmpty else { return self }

        let normalisedExceptions = Set(exceptions.map { $0.lowercased() })

        let sourceChars = Array(sourceText)
        var survivors: [Redaction] = []
        for redaction in redactions.sorted(by: { $0.position < $1.position }) {
            let start = max(0, redaction.position)
            let end = min(sourceChars.count, redaction.position + redaction.length)
            guard start < end else {
                // Defensive: out-of-range redaction. Keep it; trust upstream.
                survivors.append(redaction)
                continue
            }
            let original = String(sourceChars[start..<end])
            if normalisedExceptions.contains(original.lowercased()) {
                // Dropped — the original span stays intact in the output.
                continue
            }
            survivors.append(redaction)
        }

        // Rebuild the output text from `sourceText` with `survivors`
        // applied — more robust than mutating `anonymizedText` whose
        // offsets shift when redactions are dropped.
        var out = ""
        var cursor = 0
        for redaction in survivors {
            let start = max(0, redaction.position)
            let end = min(sourceChars.count, redaction.position + redaction.length)
            if cursor < start {
                out.append(contentsOf: sourceChars[cursor..<start])
            }
            out.append(redaction.replacement)
            cursor = end
        }
        if cursor < sourceChars.count {
            out.append(contentsOf: sourceChars[cursor..<sourceChars.count])
        }

        var newStats: [String: Int] = [:]
        for redaction in survivors {
            newStats[redaction.category, default: 0] += 1
        }

        return AnonymizationResult(
            anonymizedText: out,
            redactions: survivors,
            stats: newStats,
            processingTimeMs: processingTimeMs,
            version: version,
            flaggedForReview: flaggedForReview,
            statistics: statistics,
            auditLogPath: auditLogPath
        )
    }
}

// MARK: - Error types

enum AnonymizationError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Anonymiseringsmodellen mangler i appbunten. Prøv å installere appen på nytt."
        }
    }
}

// MARK: - Service

/// Runs Clio's native, in-process anonymization pipeline (`NativeAnonymizer`)
/// — a full Swift/CoreML port of the `no-anonymizer` Python library. Runs
/// entirely in-process (no subprocess, no embedded Python interpreter), so
/// there is no sandbox entitlement conflict with the main app's own sandbox.
///
/// Threading model:
///   - `anonymize(transcript:)` is an async function; callers may await it from any context.
///   - The native pipeline runs on `DispatchQueue.global(qos: .userInitiated)`.
///   - Results are returned to the caller's actor context (typically MainActor in the UI).
final class AnonymizationService: @unchecked Sendable {
    static let shared = AnonymizationService()

    private init() {}

    // MARK: - Public API

    func anonymize(transcript: String) async throws -> AnonymizationResult {
        guard BertNERDetector.isAvailable else {
            throw AnonymizationError.modelUnavailable
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = NativeAnonymizer.anonymize(text: transcript)
                continuation.resume(returning: result)
            }
        }
    }
}
