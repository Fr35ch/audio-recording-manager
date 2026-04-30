// VMServiceConfig.swift
// AudioRecordingManager / D2A
//
// Connection settings for the d2aDecrypter Windows service running in
// VMware Fusion. Loaded from a JSON file under
// `~/Library/Application Support/AudioRecordingManager/d2a-config.json`
// on demand — there is intentionally no compiled-in default URL because
// the IP address depends on the local VM network and force-unwrapping
// a placeholder would crash the app at first launch.

import Foundation

struct VMServiceConfig: Codable, Equatable {
    /// REST endpoint of the Windows VM, e.g. `http://192.168.65.2:8080`.
    let serviceURL: URL

    /// Mac-side path to the VMware shared folder. Files written here
    /// appear inside the Windows VM at the mapped drive (typically Z:\).
    let sharedFolderPath: URL

    /// Network timeout for individual REST calls.
    let connectionTimeout: TimeInterval

    /// Soft cap on retries for transient connection failures. The bridge
    /// service does not retry on auth failures.
    let maxRetries: Int

    init(
        serviceURL: URL,
        sharedFolderPath: URL,
        connectionTimeout: TimeInterval = 30,
        maxRetries: Int = 3
    ) {
        self.serviceURL = serviceURL
        self.sharedFolderPath = sharedFolderPath
        self.connectionTimeout = connectionTimeout
        self.maxRetries = maxRetries
    }

    /// Path to the on-disk config file. Caller is responsible for creating
    /// the parent directory (the storage layer does this on launch).
    static var configFileURL: URL {
        StorageLayout.dataRoot.appendingPathComponent("d2a-config.json")
    }

    /// Reads the config file; returns `nil` if absent. Throws on a
    /// present-but-malformed file so the user can be told to fix it
    /// rather than silently defaulting.
    static func load() throws -> VMServiceConfig? {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(VMServiceConfig.self, from: data)
    }

    /// Writes the config to disk. Used by an admin/setup flow; not
    /// invoked during normal operation.
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configFileURL, options: .atomic)
    }
}
