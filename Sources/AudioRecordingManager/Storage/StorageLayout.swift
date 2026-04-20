// StorageLayout.swift
// AudioRecordingManager
//
// Single source of truth for on-disk paths in the Phase 0 storage architecture.
//
// Architecture reference: ADR-1014 (File Storage Architecture Pivot).
// Spec: docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md
//
// This file deliberately avoids any reference to `~/Desktop/lydfiler/` or
// `~/Desktop/tekstfiler/`. The only place in the codebase that may look at
// those paths is `LegacyStorageScanner` (for migration only).

import Foundation

/// Canonical paths for the Phase 0 storage layout.
///
/// Layout:
/// ```
/// ~/Library/Application Support/AudioRecordingManager/
///   recordings/
///     <uuid>/
///       audio.m4a
///       transcript.txt
///       meta.json
///   audit/
///     audit-YYYY-MM.jsonl
///   state/
///     app.json
/// ```
///
/// All callers must go through this type rather than constructing paths by
/// string concatenation. If a new directory is introduced, add it here first.
enum StorageLayout {

    // MARK: - Root

    /// `~/Library/Application Support/AudioRecordingManager/`
    ///
    /// The root of all ARM on-disk state. MDM is configured to exclude this
    /// path from the roaming profile sync — see ADR-1014.
    static var dataRoot: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return support.appendingPathComponent("AudioRecordingManager", isDirectory: true)
    }

    // MARK: - Subdirectories

    /// `<dataRoot>/recordings/` — per-recording folders keyed by UUID.
    static var recordingsRoot: URL {
        dataRoot.appendingPathComponent("recordings", isDirectory: true)
    }

    /// `<dataRoot>/audit/` — append-only JSONL logs, monthly rotated.
    static var auditRoot: URL {
        dataRoot.appendingPathComponent("audit", isDirectory: true)
    }

    /// `<dataRoot>/state/` — app-level state (migration markers, project config).
    static var stateRoot: URL {
        dataRoot.appendingPathComponent("state", isDirectory: true)
    }

    // MARK: - Per-recording paths

    /// `<recordingsRoot>/<uuid>/`
    static func recordingFolder(id: UUID) -> URL {
        recordingsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// `<recordingsRoot>/<uuid>/audio.m4a`
    static func audioURL(id: UUID) -> URL {
        recordingFolder(id: id).appendingPathComponent("audio.m4a")
    }

    /// `<recordingsRoot>/<uuid>/transcript.txt`
    static func transcriptURL(id: UUID) -> URL {
        recordingFolder(id: id).appendingPathComponent("transcript.txt")
    }

    /// `<recordingsRoot>/<uuid>/transcript_anonymized.txt`
    ///
    /// Present when the researcher ran anonymization in ARM (either via the
    /// current in-app flow or via legacy migration from a pre-Phase-0
    /// `.metadata.json` sidecar whose `anonymizedTranscript` field was set).
    static func anonymizedTranscriptURL(id: UUID) -> URL {
        recordingFolder(id: id).appendingPathComponent("transcript_anonymized.txt")
    }

    /// `<recordingsRoot>/<uuid>/analysis.json`
    ///
    /// LLM analysis result produced by `AnalyseSectionView` via Ollama.
    static func analysisURL(id: UUID) -> URL {
        recordingFolder(id: id).appendingPathComponent("analysis.json")
    }

    /// `<recordingsRoot>/<uuid>/meta.json`
    static func metaURL(id: UUID) -> URL {
        recordingFolder(id: id).appendingPathComponent("meta.json")
    }

    // MARK: - Audit paths

    /// Audit log file for the current month, e.g. `audit-2026-04.jsonl`.
    static var currentMonthAuditLog: URL {
        auditLog(for: Date())
    }

    /// Audit log file for the month containing `date`.
    static func auditLog(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let name = "audit-\(formatter.string(from: date)).jsonl"
        return auditRoot.appendingPathComponent(name)
    }

    // MARK: - State paths

    /// `<stateRoot>/app.json` — app-level state (migration markers, etc.).
    static var appStateURL: URL {
        stateRoot.appendingPathComponent("app.json")
    }

    // MARK: - Directory creation

    /// Idempotently creates all top-level directories (`dataRoot`, `recordingsRoot`,
    /// `auditRoot`, `stateRoot`). Safe to call on every launch.
    ///
    /// Throws if creation fails for any reason other than "already exists".
    static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for url in [dataRoot, recordingsRoot, auditRoot, stateRoot] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - UUID parsing

    /// Extracts a `UUID` from a recording folder URL produced by `recordingFolder(id:)`.
    /// Returns `nil` if the last path component is not a valid UUID — such folders are
    /// ignored by enumeration so stray files in `recordings/` do not crash the app.
    static func recordingId(from url: URL) -> UUID? {
        UUID(uuidString: url.lastPathComponent)
    }
}
