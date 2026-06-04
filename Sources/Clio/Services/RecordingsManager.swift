import AVFAudio
import Foundation

// MARK: - Recordings Manager
//
// As of Phase 0 (ADR-1014), recordings live in `RecordingStore` under
// `~/Library/Application Support/AudioRecordingManager/recordings/<uuid>/`,
// not on the Desktop. This class is a thin adapter that exposes the store's
// contents as `[RecordingItem]` for the existing UI.
//
// The `RecordingItem` model is unchanged; `path` is the absolute audio file
// path (now under Application Support), and `filename` is the human-readable
// `displayName` from the sidecar — not the opaque UUID on disk.
class RecordingsManager: ObservableObject {
    static let shared = RecordingsManager()

    @Published var recordings: [RecordingItem] = []

    /// Subscription to `RecordingStore.didChangeNotification` so the list
    /// stays in sync with sidecar writes.
    private var changeObserver: NSObjectProtocol?
    private var reloadWorkItem: DispatchWorkItem?

    private init() {
        loadRecordings()
        subscribeToStoreChanges()
    }

    deinit {
        if let token = changeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Subscribe to RecordingStore notifications so the recordings list
    /// updates when sidecars change (create, finalize, updateMeta, delete).
    private func subscribeToStoreChanges() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: RecordingStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Debounce so a burst of writes doesn't trigger many reloads.
            self?.reloadWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.loadRecordings()
            }
            self?.reloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    func loadRecordings() {
        let metas = RecordingStore.shared.loadAll()
        var items: [RecordingItem] = []

        for meta in metas {
            // Skip recordings whose audio is not on disk (e.g. orphan
            // metadata records) — they shouldn't appear in the recordings
            // list. They remain in the store and surface elsewhere later.
            guard meta.audio.status == .done else { continue }

            let audioURL = StorageLayout.recordingFolder(id: meta.id)
                .appendingPathComponent(meta.audio.filename)
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }

            let size = meta.audio.sizeBytes
                ?? (try? FileManager.default
                    .attributesOfItem(atPath: audioURL.path)[.size] as? Int64)
                ?? 0

            let duration: TimeInterval
            if let stored = meta.durationSeconds, stored > 0 {
                duration = stored
            } else if let f = try? AVAudioFile(forReading: audioURL) {
                let d = Double(f.length) / f.processingFormat.sampleRate
                duration = d.isNaN ? 0 : d
            } else {
                duration = 0
            }

            items.append(
                RecordingItem(
                    id: meta.id,
                    filename: meta.displayName,
                    path: audioURL.path,
                    date: meta.createdAt,
                    size: size,
                    duration: duration
                )
            )
        }

        recordings = items.sorted { $0.date > $1.date }
        print("📋 Loaded \(recordings.count) recordings from RecordingStore")
    }

    /// Hard-deletes a recording and cascades to any analyses that
    /// reference it. Analyses are first-class entities under
    /// `<dataRoot>/analyses/`; if they keep referencing a deleted
    /// recording the result view shows stale data forever. Cascading
    /// keeps state consistent.
    ///
    /// Order matters: analyses are deleted *before* the recording so
    /// that a partial failure (recording delete throws after analyses
    /// already gone) leaves the system with a missing recording and no
    /// dangling analyses, rather than orphan analyses pointing into
    /// nothing.
    func deleteRecording(_ item: RecordingItem) {
        // Find and cascade-delete every analysis that references this
        // recording. AnalysisSource.recordingId is the link.
        let analyses = AnalysisStore.shared.loadAll()
        for analysis in analyses
            where analysis.sources.contains(where: { $0.recordingId == item.id })
        {
            do {
                try AnalysisStore.shared.delete(id: analysis.id)
                print("🗑️ Cascade-deleted analyse \(analysis.id.uuidString) (referenced \(item.filename))")
            } catch {
                print("⚠️ Could not delete linked analyse \(analysis.id.uuidString): \(error)")
            }
        }

        // Now delete the recording itself.
        do {
            try RecordingStore.shared.delete(id: item.id)
            print("🗑️ Deleted: \(item.filename)")
            // RecordingStore posts didChangeNotification; subscriber will reload.
        } catch {
            print("❌ Error deleting recording: \(error)")
        }
    }
}
