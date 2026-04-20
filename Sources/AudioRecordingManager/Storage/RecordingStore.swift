// RecordingStore.swift
// AudioRecordingManager
//
// CRUD facade over the Phase 0 storage layout. All reads and writes to
// recording folders, audio files, transcripts, and sidecars must go through
// this type. Direct filesystem manipulation outside the store is a bug.
//
// Concurrency model
// -----------------
// Two writers exist per recording: the recorder (writing audio) and the
// transcription service (writing the transcript + updating sidecar status).
// Sidecar updates are read-modify-write, which is racy if two callers update
// the same recording at the same time. To keep things correct without a full
// actor rewrite, `updateMeta` serializes all writes to a given recording
// through a per-recording `DispatchQueue`. This is the simplest thing that
// demonstrably works; we can upgrade to `actor` later if the queue map
// becomes a bottleneck.

import Foundation

// MARK: - Errors

enum RecordingStoreError: Error, CustomStringConvertible {
    case recordingNotFound(UUID)
    case invalidMetadata(UUID, underlying: Error)
    case ioFailed(URL, underlying: Error)

    var description: String {
        switch self {
        case .recordingNotFound(let id):
            return "No recording with id \(id.uuidString)."
        case .invalidMetadata(let id, let underlying):
            return "Recording \(id.uuidString) has unreadable meta.json: \(underlying)"
        case .ioFailed(let url, let underlying):
            return "IO failed for \(url.path): \(underlying)"
        }
    }
}

// MARK: - Handle

/// A lightweight handle to a recording folder. Holds the UUID; the store
/// resolves paths and metadata on demand so the handle stays valid across
/// sidecar updates.
struct RecordingHandle {
    let id: UUID
    var folder: URL { StorageLayout.recordingFolder(id: id) }
    var audioURL: URL { StorageLayout.audioURL(id: id) }
    var transcriptURL: URL { StorageLayout.transcriptURL(id: id) }
    var metaURL: URL { StorageLayout.metaURL(id: id) }
}

// MARK: - Store

final class RecordingStore {

    /// Shared instance. The store holds only queue state and no per-app
    /// assumptions, so a singleton is fine.
    static let shared = RecordingStore()

    /// Notification posted whenever a sidecar is written (create, finalize,
    /// updateMeta). `object` is the `UUID` of the affected recording.
    /// UI layers subscribe here instead of watching the filesystem.
    static let didChangeNotification = Notification.Name("RecordingStore.didChange")

    // MARK: - Private state

    /// Per-recording serial queues for read-modify-write of `meta.json`.
    /// Access to this map is itself serialized through `queueMapLock`.
    private var perRecordingQueues: [UUID: DispatchQueue] = [:]
    private let queueMapLock = NSLock()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func queue(for id: UUID) -> DispatchQueue {
        queueMapLock.lock()
        defer { queueMapLock.unlock() }
        if let q = perRecordingQueues[id] { return q }
        let q = DispatchQueue(
            label: "com.audiorecordingmanager.recordingstore.\(id.uuidString)",
            qos: .utility
        )
        perRecordingQueues[id] = q
        return q
    }

    // MARK: - Create

    /// Creates a new recording folder with an initial sidecar. Caller writes
    /// audio to `handle.audioURL` separately. Returns the handle so the
    /// caller doesn't need to re-derive paths.
    @discardableResult
    func create(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        displayName: String? = nil
    ) throws -> RecordingHandle {
        try StorageLayout.ensureDirectoriesExist()
        let handle = RecordingHandle(id: id)
        do {
            try FileManager.default.createDirectory(
                at: handle.folder,
                withIntermediateDirectories: true
            )
        } catch {
            throw RecordingStoreError.ioFailed(handle.folder, underlying: error)
        }

        let meta = RecordingMeta.new(id: id, createdAt: createdAt, displayName: displayName)
        try writeMeta(meta)
        notifyDidChange(id: id)
        return handle
    }

    // MARK: - Read

    /// Loads metadata for a single recording. Returns `nil` if the folder
    /// exists but has no sidecar — callers decide whether that's an error.
    func load(id: UUID) throws -> RecordingMeta? {
        let url = StorageLayout.metaURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RecordingStoreError.ioFailed(url, underlying: error)
        }
        do {
            return try decoder.decode(RecordingMeta.self, from: data)
        } catch {
            throw RecordingStoreError.invalidMetadata(id, underlying: error)
        }
    }

    /// Enumerates every recording in the store, newest first. Folders whose
    /// names aren't valid UUIDs are silently skipped. Folders missing a
    /// sidecar are also skipped — the caller can't do anything useful with
    /// them anyway.
    func loadAll() -> [RecordingMeta] {
        try? StorageLayout.ensureDirectoriesExist()
        let root = StorageLayout.recordingsRoot
        let fm = FileManager.default

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            print("⚠️ RecordingStore.loadAll: \(error)")
            return []
        }

        var results: [RecordingMeta] = []
        for folder in contents {
            guard let id = StorageLayout.recordingId(from: folder) else { continue }
            do {
                if let meta = try load(id: id) {
                    results.append(meta)
                }
            } catch {
                // Skip recordings with unreadable sidecars; the store's
                // caller sees all valid recordings.
                continue
            }
        }
        results.sort { $0.createdAt > $1.createdAt }
        return results
    }

    // MARK: - Update

    /// Read-modify-write of a recording's sidecar, serialized per-recording
    /// so concurrent updates don't clobber each other. The `transform`
    /// closure runs on the per-recording queue; keep it fast.
    ///
    /// Throws if the recording doesn't exist or its sidecar is unreadable.
    @discardableResult
    func updateMeta(
        id: UUID,
        transform: @escaping (inout RecordingMeta) -> Void
    ) throws -> RecordingMeta {
        let q = queue(for: id)
        var result: Result<RecordingMeta, Error>!
        q.sync {
            do {
                guard var meta = try load(id: id) else {
                    result = .failure(RecordingStoreError.recordingNotFound(id))
                    return
                }
                transform(&meta)
                try writeMeta(meta)
                result = .success(meta)
            } catch {
                result = .failure(error)
            }
        }
        let meta = try result.get()
        notifyDidChange(id: id)
        return meta
    }

    /// Convenience: marks the recording's audio as `.done` with size + optional hash.
    /// Also sets `durationSeconds` if provided. Used by the recorder on stop.
    @discardableResult
    func finalize(
        id: UUID,
        durationSeconds: Double?,
        sizeBytes: Int64?,
        sha256: String? = nil
    ) throws -> RecordingMeta {
        try updateMeta(id: id) { meta in
            meta.audio.status = .done
            meta.audio.sizeBytes = sizeBytes
            if let sha256 { meta.audio.sha256 = sha256 }
            if let durationSeconds { meta.durationSeconds = durationSeconds }
        }
    }

    // MARK: - Delete

    /// Removes a recording folder and its contents. Callers should emit an
    /// audit entry before calling this — the store has no opinion on whether
    /// a deletion is expected or not.
    func delete(id: UUID) throws {
        let folder = StorageLayout.recordingFolder(id: id)
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — treat as success.
        } catch {
            throw RecordingStoreError.ioFailed(folder, underlying: error)
        }

        // Drop the per-recording queue so we don't leak dispatch queues
        // across the lifetime of the process.
        queueMapLock.lock()
        perRecordingQueues.removeValue(forKey: id)
        queueMapLock.unlock()

        notifyDidChange(id: id)
    }

    // MARK: - Sidecar IO

    /// Writes `meta` to the recording's sidecar atomically (temp-file-then-rename
    /// via `Data.write(options: .atomic)`).
    func writeMeta(_ meta: RecordingMeta) throws {
        let url = StorageLayout.metaURL(id: meta.id)
        do {
            let data = try encoder.encode(meta)
            try data.write(to: url, options: .atomic)
        } catch {
            throw RecordingStoreError.ioFailed(url, underlying: error)
        }
    }

    // MARK: - Notifications

    private func notifyDidChange(id: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: id
            )
        }
    }
}
