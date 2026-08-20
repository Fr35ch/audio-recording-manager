import Foundation

/// Internal working representation of a detected PII span, used only during
/// the native anonymization pipeline. Mirrors Python's `no_anonymizer.models.Redaction`
/// dataclass (position/length/category/replacement/score).
///
/// Distinct from the public `Redaction` (Codable) struct in
/// `AnonymizationService.swift`, which is the external-facing result type —
/// `NativeAnonymizer` converts `PIISpan` → `Redaction` once the pipeline
/// completes.
///
/// Position/length are UTF-16 code-unit offsets into the (already
/// preprocessed) working text — the same representation `NSRegularExpression`
/// and `NSString` use throughout this pipeline. Since detection and
/// substitution both happen natively in Swift now (no cross-process JSON
/// round-trip for internal computation), there is no need to match Python's
/// Unicode-codepoint-based `str` indexing exactly.
struct PIISpan {
    var position: Int
    var length: Int
    var category: String
    var replacement: String
    var score: Double?

    var end: Int { position + length }
}
