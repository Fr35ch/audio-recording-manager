import Foundation

// MARK: - Audit types

enum AuditOutcome: String, Codable {
    case success
    case error
}

private struct AuditEntry: Codable {
    let timestamp: Date
    let recordingId: String
    let action: String
    /// Redaction counts per category — never contains actual text.
    let stats: [String: Int]?
    let processingTimeMs: Double?
    let outcome: AuditOutcome
    /// Human-readable error description if outcome == .error. Never contains transcript text.
    let errorMessage: String?
}

// MARK: - Logger

/// Append-only JSONL audit log at ~/Desktop/lydfiler/.audit_log.jsonl
///
/// Each line is one JSON object (JSONL format). The log records:
///   - timestamps, recording IDs, redaction counts — NEVER actual text content.
/// All writes are serialised through a private queue.
class AuditLogger {
    static let shared = AuditLogger()

    private let logURL: URL
    private let encoder: JSONEncoder
    /// Serial queue ensures append operations are thread-safe.
    private let queue = DispatchQueue(label: "com.audiorecordingmanager.auditlogger", qos: .utility)

    private init() {
        let audioFolder = AudioFileManager.shared.audioFolderPath
        logURL = URL(fileURLWithPath: audioFolder).appendingPathComponent(".audit_log.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Public API

    func logAnonymization(
        recordingId: String,
        stats: [String: Int]?,
        processingTimeMs: Double,
        outcome: AuditOutcome,
        errorMessage: String? = nil
    ) {
        let entry = AuditEntry(
            timestamp: Date(),
            recordingId: recordingId,
            action: "anonymization_run",
            stats: stats,
            processingTimeMs: processingTimeMs,
            outcome: outcome,
            errorMessage: errorMessage
        )
        queue.async { [self] in
            appendEntry(entry)
        }
    }

    // MARK: - Private

    private func appendEntry(_ entry: AuditEntry) {
        guard let data = try? encoder.encode(entry),
            let line = String(data: data, encoding: .utf8)
        else {
            print("❌ AuditLogger: failed to encode entry")
            return
        }

        let logLine = (line + "\n").data(using: .utf8)!

        if FileManager.default.fileExists(atPath: logURL.path) {
            guard let fileHandle = try? FileHandle(forWritingTo: logURL) else {
                print("❌ AuditLogger: could not open log file for writing")
                return
            }
            fileHandle.seekToEndOfFile()
            fileHandle.write(logLine)
            try? fileHandle.close()
        } else {
            do {
                try logLine.write(to: logURL, options: .atomic)
            } catch {
                print("❌ AuditLogger: could not create log file: \(error)")
            }
        }
    }
}
