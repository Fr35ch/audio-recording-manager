// LegacyMetadataMigrator.swift
// AudioRecordingManager
//
// Second-pass migration that processes pre-Phase-0 artefacts left behind
// by the primary `StorageMigrator` pass:
//
//   - Legacy `.metadata.json` sidecar files on the Desktop (both
//     `~/Desktop/lydfiler/` and `~/Desktop/tekstfiler/`). These carry the
//     `originalTranscript` (and possibly `anonymizedTranscript`) inline
//     rather than as separate `.txt` files. The primary pass only moved
//     `.m4a` and `.txt`, so the sidecars were stranded.
//   - Non-`.m4a` audio on the Desktop, e.g. `DS950008.MP3` from the
//     Olympus DS-9500 recorder. The primary pass only moved `.m4a`.
//   - The legacy `.audit_log.jsonl` dotfile inside `~/Desktop/lydfiler/`,
//     which has been replaced by the Application-Support-hosted audit log.
//
// The pass is idempotent and gated independently of the primary pass via
// `AppState.legacyMetadataCleanedAt`, so users upgrading from a build that
// only had the first pass get this one on the next launch.
//
// This file and `LegacyStorageScanner` are the only files allowed to
// reference `~/Desktop/`.

import Foundation

// MARK: - Outcome

struct LegacyMetadataMigrationOutcome: Equatable {
    var transcriptsMigrated: Int            // originalTranscript → transcript.txt
    var anonymizedMigrated: Int             // anonymizedTranscript → transcript_anonymized.txt
    var orphanRecordingsCreated: Int        // metadata.json with no existing recording
    var nonM4AAudioMigrated: Int            // e.g. DS950008.MP3 → new recording folder
    var legacyAuditLogRemoved: Bool
    var metadataFilesRemoved: Int
    var errorCount: Int
    var completedAt: Date?
    var wasSkipped: Bool

    static let skipped = LegacyMetadataMigrationOutcome(
        transcriptsMigrated: 0,
        anonymizedMigrated: 0,
        orphanRecordingsCreated: 0,
        nonM4AAudioMigrated: 0,
        legacyAuditLogRemoved: false,
        metadataFilesRemoved: 0,
        errorCount: 0,
        completedAt: nil,
        wasSkipped: true
    )
}

// MARK: - Legacy schema

/// Mirrors the pre-Phase-0 `RecordingMetadata` struct (see
/// `RecordingMetadata.swift`) just enough for the migrator to decode. Kept
/// here so the migrator remains self-contained if the original type is
/// eventually removed.
private struct LegacyRecordingMetadata: Decodable {
    let recordingId: String?
    let originalTranscript: String?
    let anonymizedTranscript: String?
    let anonymizationDate: Date?
    let anonymizationStats: [String: Int]?
}

// MARK: - Additional scanner scope

extension LegacyStorageScanner {
    /// Enumerates every `.metadata.json` file under the two legacy Desktop
    /// folders. Does not include hidden files. Returns `[]` if neither folder
    /// exists.
    static func legacyMetadataFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        for root in [legacyAudioFolder, legacyTranscriptFolder] {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                    values.isRegularFile == true
                else { continue }
                // Match `<stem>.metadata.json` specifically, not all `.json`.
                guard url.pathExtension.lowercased() == "json",
                      url.deletingPathExtension().pathExtension.lowercased() == "metadata"
                else { continue }
                results.append(url)
            }
        }
        return results
    }

    /// Enumerates audio files on the Desktop that the primary pass did not
    /// migrate (anything whose extension is not `.m4a`). The Olympus
    /// recorder output shows up as `.MP3`; other formats may appear over
    /// time.
    static func legacyNonM4AAudio() -> [URL] {
        let extensions: Set<String> = ["mp3", "wav", "aac", "ds2", "dss", "aiff", "aif"]
        let fm = FileManager.default
        let root = legacyAudioFolder
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            if extensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results
    }

    /// Absolute path to the legacy `.audit_log.jsonl` if present, `nil` otherwise.
    static var legacyAuditLog: URL? {
        let url = legacyAudioFolder.appendingPathComponent(".audit_log.jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Migrator

enum LegacyMetadataMigrator {

    /// Runs the follow-up pass if it has not already run on this machine.
    /// Processes every legacy `.metadata.json`, moves non-`.m4a` audio into
    /// new recording folders, and removes the legacy `.audit_log.jsonl`.
    /// Errors on individual files are recorded but do not abort the pass.
    @discardableResult
    static func runIfNeeded() throws -> LegacyMetadataMigrationOutcome {
        var state = AppStateStore.load()
        if state.legacyMetadataCleanedAt != nil {
            return .skipped
        }

        try StorageLayout.ensureDirectoriesExist()

        // Build an index of existing recordings keyed by displayName (which
        // the primary pass set to the original filename stem). This lets us
        // attach legacy transcripts to already-migrated audio.
        var recordingsByStem: [String: UUID] = [:]
        for meta in RecordingStore.shared.loadAll() {
            recordingsByStem[meta.displayName] = meta.id
        }

        var transcriptsMigrated = 0
        var anonymizedMigrated = 0
        var orphanRecordingsCreated = 0
        var nonM4AAudioMigrated = 0
        var metadataFilesRemoved = 0
        var errorCount = 0

        // 1) Process `.metadata.json` files.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for metadataURL in LegacyStorageScanner.legacyMetadataFiles() {
            do {
                let data = try Data(contentsOf: metadataURL)
                let legacy = try decoder.decode(LegacyRecordingMetadata.self, from: data)

                // Derive stem: prefer `recordingId` field; fall back to filename
                // stripped of `.metadata.json` extensions.
                let stem = legacy.recordingId ?? metadataURL
                    .deletingPathExtension()           // drop .json
                    .deletingPathExtension()           // drop .metadata
                    .lastPathComponent

                let hasTranscript = !(legacy.originalTranscript ?? "").isEmpty
                let hasAnonymized = !(legacy.anonymizedTranscript ?? "").isEmpty

                if let existingId = recordingsByStem[stem] {
                    // Attach to an already-migrated recording.
                    try attach(
                        legacy: legacy,
                        to: existingId,
                        transcriptsMigrated: &transcriptsMigrated,
                        anonymizedMigrated: &anonymizedMigrated
                    )
                } else if hasTranscript || hasAnonymized {
                    // Orphan — metadata has content but no paired audio.
                    let id = try createOrphanRecording(stem: stem, legacy: legacy)
                    recordingsByStem[stem] = id
                    orphanRecordingsCreated += 1
                    if hasTranscript { transcriptsMigrated += 1 }
                    if hasAnonymized { anonymizedMigrated += 1 }
                }
                // else: empty metadata, nothing to migrate — drop it.

                try FileManager.default.removeItem(at: metadataURL)
                metadataFilesRemoved += 1
            } catch {
                print("⚠️ LegacyMetadataMigrator: \(metadataURL.lastPathComponent) — \(error)")
                errorCount += 1
            }
        }

        // 2) Move non-`.m4a` audio into new recording folders.
        for audioURL in LegacyStorageScanner.legacyNonM4AAudio() {
            do {
                try moveNonM4AAudio(at: audioURL)
                nonM4AAudioMigrated += 1
            } catch {
                print("⚠️ LegacyMetadataMigrator: could not move \(audioURL.lastPathComponent) — \(error)")
                errorCount += 1
            }
        }

        // 3) Remove the legacy audit log dotfile.
        var legacyAuditLogRemoved = false
        if let legacyLog = LegacyStorageScanner.legacyAuditLog {
            do {
                try FileManager.default.removeItem(at: legacyLog)
                legacyAuditLogRemoved = true
            } catch {
                print("⚠️ LegacyMetadataMigrator: could not remove legacy audit log — \(error)")
                errorCount += 1
            }
        }

        // 4) Best-effort cleanup of empty legacy folders (including `.DS_Store`).
        removeEmptyLegacyFolders()

        // 5) Mark done.
        let now = Date()
        state.legacyMetadataCleanedAt = now
        try AppStateStore.save(state)

        return LegacyMetadataMigrationOutcome(
            transcriptsMigrated: transcriptsMigrated,
            anonymizedMigrated: anonymizedMigrated,
            orphanRecordingsCreated: orphanRecordingsCreated,
            nonM4AAudioMigrated: nonM4AAudioMigrated,
            legacyAuditLogRemoved: legacyAuditLogRemoved,
            metadataFilesRemoved: metadataFilesRemoved,
            errorCount: errorCount,
            completedAt: now,
            wasSkipped: false
        )
    }

    // MARK: - Attach

    private static func attach(
        legacy: LegacyRecordingMetadata,
        to id: UUID,
        transcriptsMigrated: inout Int,
        anonymizedMigrated: inout Int
    ) throws {
        let transcript = legacy.originalTranscript ?? ""
        let anonymized = legacy.anonymizedTranscript ?? ""

        if !transcript.isEmpty {
            let url = StorageLayout.transcriptURL(id: id)
            // Don't clobber a migrated `.txt` transcript — the primary pass
            // already moved one, which is authoritative.
            if !FileManager.default.fileExists(atPath: url.path) {
                try transcript.data(using: .utf8)?.write(to: url, options: .atomic)
                try RecordingStore.shared.updateMeta(id: id) { meta in
                    meta.transcript.status = .done
                }
                transcriptsMigrated += 1
            }
        }

        if !anonymized.isEmpty {
            let url = StorageLayout.anonymizedTranscriptURL(id: id)
            try anonymized.data(using: .utf8)?.write(to: url, options: .atomic)
            try RecordingStore.shared.updateMeta(id: id) { meta in
                meta.anonymization.status = .done
                meta.anonymization.completedAt = legacy.anonymizationDate
                meta.anonymization.filename = "transcript_anonymized.txt"
                meta.anonymization.stats = legacy.anonymizationStats
            }
            anonymizedMigrated += 1
        }
    }

    // MARK: - Orphan recording

    private static func createOrphanRecording(
        stem: String,
        legacy: LegacyRecordingMetadata
    ) throws -> UUID {
        let id = UUID()
        let handle = try RecordingStore.shared.create(
            id: id,
            createdAt: legacy.anonymizationDate ?? Date(),
            displayName: stem
        )

        if let transcript = legacy.originalTranscript, !transcript.isEmpty {
            try transcript.data(using: .utf8)?.write(to: handle.transcriptURL, options: .atomic)
        }
        if let anonymized = legacy.anonymizedTranscript, !anonymized.isEmpty {
            let url = StorageLayout.anonymizedTranscriptURL(id: id)
            try anonymized.data(using: .utf8)?.write(to: url, options: .atomic)
        }

        try RecordingStore.shared.updateMeta(id: id) { meta in
            meta.audio.status = .missing
            if !(legacy.originalTranscript ?? "").isEmpty {
                meta.transcript.status = .done
            }
            if !(legacy.anonymizedTranscript ?? "").isEmpty {
                meta.anonymization.status = .done
                meta.anonymization.completedAt = legacy.anonymizationDate
                meta.anonymization.filename = "transcript_anonymized.txt"
                meta.anonymization.stats = legacy.anonymizationStats
            }
        }
        return id
    }

    // MARK: - Non-m4a audio

    /// Moves a non-`.m4a` audio file into a new recording folder, preserving
    /// the original extension. The sidecar's `audio.filename` is updated to
    /// reflect the preserved extension.
    private static func moveNonM4AAudio(at source: URL) throws {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension  // preserve original case

        let createdAt = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }

        let id = UUID()
        let handle = try RecordingStore.shared.create(
            id: id,
            createdAt: createdAt,
            displayName: stem
        )

        // Destination uses `audio.<ext>` so the non-standard extension is kept.
        let destFilename = "audio.\(ext)"
        let destURL = handle.folder.appendingPathComponent(destFilename)
        try FileManager.default.moveItem(at: source, to: destURL)

        try RecordingStore.shared.updateMeta(id: id) { meta in
            meta.audio.filename = destFilename
            meta.audio.sizeBytes = size
            meta.audio.status = .done
        }
    }

    // MARK: - Cleanup

    private static func removeEmptyLegacyFolders() {
        let fm = FileManager.default
        for root in [LegacyStorageScanner.legacyAudioFolder, LegacyStorageScanner.legacyTranscriptFolder] {
            guard fm.fileExists(atPath: root.path) else { continue }
            // Walk subfolders bottom-up so we can clean them too.
            if let subpaths = try? fm.contentsOfDirectory(atPath: root.path) {
                for sub in subpaths {
                    let subURL = root.appendingPathComponent(sub)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: subURL.path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue {
                        removeIfEmpty(subURL)
                    } else if sub == ".DS_Store" {
                        try? fm.removeItem(at: subURL)
                    }
                }
            }
            removeIfEmpty(root)
        }
    }

    private static func removeIfEmpty(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        // A folder with only `.DS_Store` counts as empty — remove it too.
        if let contents = try? fm.contentsOfDirectory(atPath: url.path) {
            let meaningful = contents.filter { $0 != ".DS_Store" }
            if meaningful.isEmpty {
                let ds = url.appendingPathComponent(".DS_Store")
                try? fm.removeItem(at: ds)
                try? fm.removeItem(at: url)
            }
        }
    }
}
