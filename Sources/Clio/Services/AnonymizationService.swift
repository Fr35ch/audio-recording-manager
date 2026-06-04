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
    case bridgeScriptNotFound
    case libraryNotInstalled
    case timeout
    case processFailed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .bridgeScriptNotFound:
            return "Anonymiseringsskript ikke funnet i appbunten"
        case .libraryNotInstalled:
            return """
            no-anonymizer er ikke installert. Installer via:
              pip install "no-anonymizer[ner]"
            """
        case .timeout:
            return "Anonymisering tok for lang tid (maks 3 minutter). Prøv igjen."
        case .processFailed(let message):
            return "Anonymisering feilet: \(message)"
        case .invalidOutput:
            return "Uventet svar fra anonymiseringstjenesten"
        }
    }
}

// MARK: - Service

/// Calls the no-anonymizer Python library via a subprocess bridge script.
///
/// Threading model:
///   - `anonymize(transcript:)` is an async function; callers may await it from any context.
///   - The underlying subprocess runs on `DispatchQueue.global(qos: .userInitiated)`.
///   - Results are returned to the caller's actor context (typically MainActor in the UI).
final class AnonymizationService: @unchecked Sendable {
    static let shared = AnonymizationService()

    private init() {}

    // MARK: - Public API

    func anonymize(transcript: String) async throws -> AnonymizationResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runSubprocess(transcript: transcript)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Subprocess execution

    private func bridgeScriptURL() -> URL? {
        // 1. App bundle Resources (production)
        if let url = Bundle.main.url(forResource: "anonymize_bridge", withExtension: "py") {
            return url
        }
        // 2. Development fallback: project root Resources/
        let devPath =
            FileManager.default.currentDirectoryPath + "/Resources/anonymize_bridge.py"
        if FileManager.default.fileExists(atPath: devPath) {
            return URL(fileURLWithPath: devPath)
        }
        return nil
    }

    /// Returns the Python executable to use, preferring the no-anonymizer dev venv.
    ///
    /// Priority:
    ///   1. `~/Github/no-anonymizer/.venv/bin/python3` — local development venv
    ///   2. `python3` via login shell PATH — production / globally installed
    private func pythonExecutable() -> String {
        let candidates = [
            (NSHomeDirectory() as NSString).appendingPathComponent(
                "Github/no-anonymizer/.venv/bin/python3")
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path.armShellEscaped
        }
        return "python3"  // resolved via login-shell PATH
    }

    private func runSubprocess(transcript: String) throws -> AnonymizationResult {
        guard let scriptURL = bridgeScriptURL() else {
            throw AnonymizationError.bridgeScriptNotFound
        }

        // Write transcript to a temp file (avoids shell quoting issues with arbitrary text)
        let tmp = FileManager.default.temporaryDirectory
        let uid = UUID().uuidString
        let inputURL = tmp.appendingPathComponent("arm_anon_in_\(uid).txt")
        let outputURL = tmp.appendingPathComponent("arm_anon_out_\(uid).json")

        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try transcript.write(to: inputURL, atomically: true, encoding: .utf8)

        // Use the best available Python; login shell so Homebrew/pyenv PATH is also available
        //
        // ⏳ Phase A.2 deferred: no-anonymizer v2 will accept `--strict-mode`
        // to suppress the new three-way `flag` bucket and behave like v1.
        // Adding the flag here would break v1 (the flag doesn't exist
        // yet upstream), so leave the args minimal until v2 ships in
        // github.com/Fr35ch/no-anonymizer. When v2 lands, append
        // `--strict-mode` unconditionally until the "Til gjennomgang" UI
        // ships in `AvidentifiseringSheet` (Phase B), at which point the
        // flag is dropped and ARM consumes `flagged_for_review` directly.
        // Spec: docs/no_anonymizer_v2_implementasjon.md §10.
        let cmd = "\(pythonExecutable()) \(scriptURL.path.armShellEscaped) "
            + "--input \(inputURL.path.armShellEscaped) "
            + "--output \(outputURL.path.armShellEscaped)"

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-lc", cmd]

        let stderrPipe = Pipe()
        task.standardError = stderrPipe

        do {
            try task.run()
        } catch {
            throw AnonymizationError.processFailed(error.localizedDescription)
        }

        // Poll for completion with 30-second timeout
        let deadline = Date().addingTimeInterval(180)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                throw AnonymizationError.timeout
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let exitCode = task.terminationStatus

        switch exitCode {
        case 0:
            break // success — fall through to JSON parsing
        case 3:
            throw AnonymizationError.libraryNotInstalled
        default:
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText =
                String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit code \(exitCode)"
            // Try to extract the message field from the JSON error payload the bridge writes
            let humanMessage = extractBridgeErrorMessage(from: errText) ?? errText
            throw AnonymizationError.processFailed(humanMessage)
        }

        // Parse output JSON
        guard let data = try? Data(contentsOf: outputURL) else {
            throw AnonymizationError.invalidOutput
        }
        let decoder = JSONDecoder()
        guard let result = try? decoder.decode(AnonymizationResult.self, from: data) else {
            throw AnonymizationError.invalidOutput
        }
        return result
    }

    // MARK: - Helpers

    private func extractBridgeErrorMessage(from stderrText: String) -> String? {
        guard let data = stderrText.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let msg = obj["message"] as? String
        else { return nil }
        return msg
    }
}

// MARK: - String helper

private extension String {
    /// Shell-escapes a path by wrapping in single quotes and escaping any embedded single quotes.
    var armShellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
