// AppState.swift
// AudioRecordingManager
//
// App-level state persisted as `state/app.json` inside the ARM data root.
// Currently holds the migration marker so the one-shot legacy-Desktop
// migration only runs once. Future phases will add project configuration
// (Teams destination, etc.) here.
//
// Reads and writes go through atomic temp-file-then-rename to avoid corrupt
// state if the app is killed mid-write.

import Foundation

struct AppState: Codable, Equatable {
    /// Bumped when backwards-incompatible changes are made to this schema.
    static let currentSchemaVersion: Int = 1

    var schemaVersion: Int
    /// When the primary one-shot audio+transcript migration completed.
    /// `nil` means it has not run yet (or ran on a pre-Phase-0 build).
    /// The primary pass moves `.m4a` and `.txt` files and is separate from
    /// the legacy-metadata follow-up pass tracked by
    /// `legacyMetadataCleanedAt`.
    var migrationCompletedAt: Date?
    /// Number of recordings migrated on the one-shot pass. Useful for the
    /// post-migration confirmation message.
    var migrationRecordingCount: Int?
    /// When the follow-up pass that processes legacy `.metadata.json` files,
    /// non-`.m4a` Desktop audio, and cleans up the legacy audit log
    /// completed. `nil` means the follow-up has not run. This marker is
    /// **separate** from `migrationCompletedAt` so that users upgrading from
    /// the first-pass-only version still get their legacy metadata migrated
    /// on next launch without needing a manual reset.
    var legacyMetadataCleanedAt: Date?

    init(
        schemaVersion: Int = AppState.currentSchemaVersion,
        migrationCompletedAt: Date? = nil,
        migrationRecordingCount: Int? = nil,
        legacyMetadataCleanedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.migrationCompletedAt = migrationCompletedAt
        self.migrationRecordingCount = migrationRecordingCount
        self.legacyMetadataCleanedAt = legacyMetadataCleanedAt
    }

    // MARK: - Forward-compat Codable

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case migrationCompletedAt
        case migrationRecordingCount
        case legacyMetadataCleanedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        migrationCompletedAt = try c.decodeIfPresent(Date.self, forKey: .migrationCompletedAt)
        migrationRecordingCount = try c.decodeIfPresent(Int.self, forKey: .migrationRecordingCount)
        legacyMetadataCleanedAt = try c.decodeIfPresent(Date.self, forKey: .legacyMetadataCleanedAt)
    }
}

// MARK: - Store

/// Persists `AppState` to `StorageLayout.appStateURL` with atomic writes and
/// safe defaults when the file is absent or corrupt.
enum AppStateStore {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Loads current state. Returns a fresh empty `AppState` if the file is
    /// missing or unreadable — callers should not treat a missing state file
    /// as an error.
    static func load() -> AppState {
        let url = StorageLayout.appStateURL
        guard
            let data = try? Data(contentsOf: url),
            let state = try? decoder.decode(AppState.self, from: data)
        else {
            return AppState()
        }
        return state
    }

    /// Atomically writes `state` to disk. Ensures the parent directory exists.
    /// Throws on any IO failure.
    static func save(_ state: AppState) throws {
        try StorageLayout.ensureDirectoriesExist()
        let data = try encoder.encode(state)
        try data.write(to: StorageLayout.appStateURL, options: .atomic)
    }

    /// Convenience: read, mutate, write. Callers pass a transform closure
    /// that receives an inout copy and may mutate any field.
    @discardableResult
    static func update(_ transform: (inout AppState) -> Void) throws -> AppState {
        var state = load()
        transform(&state)
        try save(state)
        return state
    }
}
