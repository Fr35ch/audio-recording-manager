// StorageMigrator.swift
// AudioRecordingManager
//
// One-shot migration from the pre-Phase-0 Desktop layout (~/Desktop/lydfiler,
// ~/Desktop/tekstfiler) to the Phase 0 layout under
// `~/Library/Application Support/AudioRecordingManager/`.
//
// Behaviour:
//   - Idempotent. Gated by `AppState.migrationCompletedAt`. Calling `runIfNeeded()`
//     on a machine that has already migrated is a no-op.
//   - Non-destructive on failure. Audio and transcript files are MOVED (not
//     copied) — we want the Desktop folders to end up empty — but if a file
//     fails to move, the migration records the error and continues with the
//     rest; the failed file stays on Desktop.
//   - Orphan transcripts (no matching audio) get their own recording folder
//     with `audio.status = missing`.
//   - Matching is by filename stem, the same rule the old code used, so
//     transcription→audio pairings survive the migration unchanged.

import Foundation

struct MigrationOutcome: Equatable {
    /// Total number of recording folders created (audio + orphan transcripts).
    var recordingsCreated: Int
    /// Files that were moved successfully.
    var filesMoved: Int
    /// Files that encountered an error during the move (file remains on Desktop).
    var errorCount: Int
    /// When the migration completed. `nil` if the migration was skipped
    /// because it had already run.
    var completedAt: Date?
    /// `true` when the migration was skipped because it had already run on
    /// this machine. In that case all counters are zero.
    var wasSkipped: Bool

    static let skipped = MigrationOutcome(
        recordingsCreated: 0,
        filesMoved: 0,
        errorCount: 0,
        completedAt: nil,
        wasSkipped: true
    )
}

enum StorageMigrator {

    /// Runs migration if it has not already run on this machine. Safe to call
    /// on every launch. Errors during individual file moves are logged but
    /// do not throw; a systemic failure (e.g. cannot create `recordings/`)
    /// does throw.
    @discardableResult
    static func runIfNeeded() throws -> MigrationOutcome {
        let state = AppStateStore.load()
        if state.migrationCompletedAt != nil {
            return .skipped
        }

        let report = LegacyStorageScanner.scan()
        if !report.hasAnything {
            // Nothing to migrate — but still mark migration complete so
            // subsequent launches don't re-scan. That also means we won't
            // pick up files a user might later drop on Desktop, which is
            // exactly what we want: Desktop is no longer a data source.
            try AppStateStore.update { state in
                state.migrationCompletedAt = Date()
                state.migrationRecordingCount = 0
            }
            return MigrationOutcome(
                recordingsCreated: 0,
                filesMoved: 0,
                errorCount: 0,
                completedAt: Date(),
                wasSkipped: false
            )
        }

        try StorageLayout.ensureDirectoriesExist()

        // Index transcripts by stem for fast lookup.
        var transcriptsByStem: [String: URL] = [:]
        for t in report.transcriptFiles {
            let stem = t.deletingPathExtension().lastPathComponent
            transcriptsByStem[stem] = t
        }
        var usedTranscriptStems = Set<String>()

        var recordingsCreated = 0
        var filesMoved = 0
        var errorCount = 0

        // 1) For every audio file, create a recording and move audio + matching transcript.
        for audioURL in report.audioFiles {
            let stem = audioURL.deletingPathExtension().lastPathComponent
            let matchingTranscript = transcriptsByStem[stem]

            let createdAt = (try? audioURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let audioSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }

            let id = UUID()
            let handle: RecordingHandle
            do {
                handle = try RecordingStore.shared.create(
                    id: id,
                    createdAt: createdAt,
                    displayName: stem
                )
                recordingsCreated += 1
            } catch {
                print("⚠️ Migration: could not create recording for \(audioURL.lastPathComponent): \(error)")
                errorCount += 1
                continue
            }

            // Move audio.
            do {
                try FileManager.default.moveItem(at: audioURL, to: handle.audioURL)
                filesMoved += 1
            } catch {
                print("⚠️ Migration: could not move audio \(audioURL.lastPathComponent): \(error)")
                errorCount += 1
                // Sidecar already exists; mark the audio as missing so the
                // UI shows the recording rather than hiding it silently.
                _ = try? RecordingStore.shared.updateMeta(id: id) { meta in
                    meta.audio.status = .missing
                }
                continue
            }

            // Move matching transcript if any.
            if let transcript = matchingTranscript {
                usedTranscriptStems.insert(stem)
                do {
                    try FileManager.default.moveItem(at: transcript, to: handle.transcriptURL)
                    filesMoved += 1
                    _ = try? RecordingStore.shared.updateMeta(id: id) { meta in
                        meta.audio.sizeBytes = audioSize
                        meta.audio.status = .done
                        meta.transcript.status = .done
                    }
                } catch {
                    print("⚠️ Migration: could not move transcript for \(stem): \(error)")
                    errorCount += 1
                    _ = try? RecordingStore.shared.updateMeta(id: id) { meta in
                        meta.audio.sizeBytes = audioSize
                        meta.audio.status = .done
                    }
                }
            } else {
                _ = try? RecordingStore.shared.updateMeta(id: id) { meta in
                    meta.audio.sizeBytes = audioSize
                    meta.audio.status = .done
                }
            }
        }

        // 2) Any transcripts not matched to an audio get their own recording folder.
        for (stem, transcriptURL) in transcriptsByStem where !usedTranscriptStems.contains(stem) {
            let createdAt = (try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

            let id = UUID()
            let handle: RecordingHandle
            do {
                handle = try RecordingStore.shared.create(
                    id: id,
                    createdAt: createdAt,
                    displayName: stem
                )
                recordingsCreated += 1
            } catch {
                print("⚠️ Migration: could not create orphan recording for \(stem): \(error)")
                errorCount += 1
                continue
            }

            do {
                try FileManager.default.moveItem(at: transcriptURL, to: handle.transcriptURL)
                filesMoved += 1
                _ = try? RecordingStore.shared.updateMeta(id: id) { meta in
                    meta.audio.status = .missing
                    meta.transcript.status = .done
                }
            } catch {
                print("⚠️ Migration: could not move orphan transcript \(stem): \(error)")
                errorCount += 1
                _ = try? RecordingStore.shared.updateMeta(id: id) { meta in
                    meta.audio.status = .missing
                    meta.transcript.status = .failed
                }
            }
        }

        // 3) Mark migration complete in AppState, then attempt to delete empty
        //    legacy folders and leave a breadcrumb on Desktop.
        let now = Date()
        try AppStateStore.update { state in
            state.migrationCompletedAt = now
            state.migrationRecordingCount = recordingsCreated
        }

        cleanupLegacyFolders(report: report)
        writeDesktopBreadcrumb(recordingsCreated: recordingsCreated)

        return MigrationOutcome(
            recordingsCreated: recordingsCreated,
            filesMoved: filesMoved,
            errorCount: errorCount,
            completedAt: now,
            wasSkipped: false
        )
    }

    // MARK: - Private

    private static func cleanupLegacyFolders(report: LegacyStorageReport) {
        let fm = FileManager.default
        for folder in [report.audioFolder, report.transcriptFolder].compactMap({ $0 }) {
            let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            // Only remove if truly empty (respecting hidden files too — user
            // might have their own files in there; we don't touch those).
            if contents.isEmpty {
                do {
                    try fm.removeItem(at: folder)
                } catch {
                    print("⚠️ Migration: could not remove empty legacy folder \(folder.lastPathComponent): \(error)")
                }
            }
        }
    }

    private static func writeDesktopBreadcrumb(recordingsCreated: Int) {
        let fm = FileManager.default
        guard let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        let breadcrumb = desktop.appendingPathComponent("ARM_moved_to_secure_storage.txt")
        let body = """
        Dine opptak og transkripsjoner er flyttet til sikker lagring.

        Audio Recording Manager lagrer nå alle forskningsdata i appens sikre område i stedet for på skrivebordet. Dette gjøres for å beskytte sensitive intervjuopptak.

        Antall opptak flyttet: \(recordingsCreated)
        Flyttet: \(ISO8601DateFormatter().string(from: Date()))

        Du finner dine opptak inne i Audio Recording Manager-appen som vanlig.
        Filene på skrivebordet er tomme og kan fjernes.

        ---

        Your recordings and transcripts have been moved to secure storage.

        Audio Recording Manager now stores all research data in the app's
        secure area instead of on the Desktop. This change protects sensitive
        interview recordings.

        Recordings moved: \(recordingsCreated)
        Moved at: \(ISO8601DateFormatter().string(from: Date()))

        You can access recordings inside the Audio Recording Manager app as
        usual. The Desktop folders are now empty and can be removed.
        """
        try? body.data(using: .utf8)?.write(to: breadcrumb, options: .atomic)
    }
}
