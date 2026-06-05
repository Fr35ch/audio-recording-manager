// MobileTransferImporter.swift
// Clio
//
// Takes a WAV file downloaded from a Clio Recorder iOS device and imports it
// into the RecordingStore as a proper recording entry.
//
// RODE dual-channel detection
// ---------------------------
// The iOS app embeds a `RODE_DUAL_CHANNEL` marker in the WAV INFO chunk /
// BEXT originator field (spec § 9.4). This importer checks for that marker
// and sets `mobileImport.isDualChannel` on the resulting RecordingMeta so
// the transcription pipeline can apply the split → transcribe → merge flow.
//
// Staging cleanup
// ---------------
// The staging WAV (under mobileInboxURL) is moved — not copied — into the
// recording folder as `audio.wav`. The staging directory is cleaned up after
// a successful import.

import Foundation

// MARK: - Import result

struct MobileImportResult {
    let recordingId: UUID
    let isDualChannel: Bool
}

// MARK: - Importer

actor MobileTransferImporter {

    // MARK: - Public

    /// Imports a downloaded WAV from `stagingURL` into the RecordingStore.
    /// - Parameters:
    ///   - stagingURL: Temporary path returned by `MobileTransferClient.downloadRecording`
    ///   - info: Recording metadata from the iOS list endpoint
    ///   - deviceName: Display name of the source iOS device
    func importRecording(
        stagingURL: URL,
        info: MobileRecordingInfo,
        deviceName: String
    ) async throws -> MobileImportResult {
        let isDualChannel = info.isDualChannel || (try? Self.detectDualChannelMarker(at: stagingURL)) == true
        let newId = UUID()
        let folder = StorageLayout.recordingFolder(id: newId)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let destinationURL = folder.appendingPathComponent("audio.wav")
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)

        var meta = RecordingMeta.new(
            id: newId,
            createdAt: info.recordedAt ?? Date(),
            displayName: Self.displayName(from: info.filename, date: info.recordedAt)
        )
        meta.durationSeconds = info.durationSeconds
        meta.audio = AudioMeta(
            filename: "audio.wav",
            status: .done,
            sizeBytes: info.sizeBytes
        )
        meta.mobileImport = MobileImportMeta(
            iOSDeviceName: deviceName,
            originalFilename: info.filename,
            importedAt: Date(),
            isDualChannel: isDualChannel,
            iOSRecordingId: info.id
        )

        try RecordingStore.shared.create(meta: meta)

        return MobileImportResult(recordingId: newId, isDualChannel: isDualChannel)
    }

    // MARK: - Private helpers

    /// Scans the first 4 KB of a WAV file for the RODE_DUAL_CHANNEL marker.
    /// The marker is embedded in the BEXT originator field or INFO chunk by
    /// the iOS Clio Recorder app (spec § 9.4).
    private static func detectDualChannelMarker(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header: Data
        if #available(macOS 10.15.4, *) {
            header = try handle.read(upToCount: 4096) ?? Data()
        } else {
            header = handle.readData(ofLength: 4096)
        }
        let marker = "RODE_DUAL_CHANNEL".data(using: .ascii)!
        return header.range(of: marker) != nil
    }

    private static func displayName(from filename: String, date: Date?) -> String {
        // Strip extension and underscores for a readable label
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let readable = stem.replacingOccurrences(of: "_", with: " ")
        return readable.isEmpty ? RecordingMeta.defaultDisplayName(for: date ?? Date()) : readable
    }
}
