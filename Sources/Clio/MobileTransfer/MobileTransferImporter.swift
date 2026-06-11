// MobileTransferImporter.swift
// Clio
//
// Takes a WAV file downloaded from a Clio Recorder iOS device and imports it
// into the RecordingStore as a proper recording entry.
//
// Format conversion
// -----------------
// The iOS app sends WAV. The RecordingStore expects audio.m4a (AAC in MPEG-4).
// The importer converts the staging WAV to M4A using AVAssetExportSession
// before writing to the recording folder.
//
// RODE dual-channel detection
// ---------------------------
// The iOS app embeds a `RODE_DUAL_CHANNEL` marker in the WAV INFO chunk /
// BEXT originator field (spec § 9.4). This importer checks for that marker
// before conversion and sets `mobileImport.isDualChannel` on the resulting
// RecordingMeta so the transcription pipeline can apply the
// split → transcribe → merge flow.

import Foundation
import AVFoundation

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
        deviceName: String,
        sidecarData: Data? = nil
    ) async throws -> MobileImportResult {
        // Prefer the authoritative sidecar flag; fall back to detection.
        let receivedMeta = sidecarData.flatMap(ClioMeta.decode(from:))
        let isDualChannel: Bool
        if let receivedMeta {
            isDualChannel = !receivedMeta.diarizationRequired
        } else {
            isDualChannel = (info.isDualChannel == true)
                || (try? Self.detectDualChannelMarker(at: stagingURL)) == true
        }
        let newId = UUID()
        let folder = StorageLayout.recordingFolder(id: newId)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Convert WAV → M4A so the recording is consistent with the store format
        let destinationURL = StorageLayout.audioURL(id: newId)
        try await Self.convertToM4A(from: stagingURL, to: destinationURL)
        try? FileManager.default.removeItem(at: stagingURL)

        // Write the ClioMeta sidecar (audio.meta.json) next to the converted audio
        // so transcribe() routes dual-channel recordings to the channel split.
        if isDualChannel {
            let metaToWrite = receivedMeta ?? ClioMeta.rodeDualChannelDefault()
            do {
                try metaToWrite.write(for: destinationURL)
            } catch {
                NSLog("[MobileTransferImporter] Failed to write ClioMeta sidecar: \(error)")
                // Non-fatal — the transcribe() mobileImport fallback still routes the split.
            }
        }

        var meta = RecordingMeta.new(
            id: newId,
            createdAt: info.recordedAt ?? Date(),
            displayName: Self.displayName(from: info.filename, date: info.recordedAt)
        )
        meta.durationSeconds = info.durationSeconds
        meta.audio = AudioMeta(
            filename: "audio.m4a",
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

    /// Imports a recording file that arrived out-of-band (e.g. via AirDrop into
    /// `~/Downloads`). Metadata is synthesized from the file itself since there
    /// is no companion list endpoint.
    /// - Parameters:
    ///   - fileURL: A `.wav` or `.m4a` file produced by Clio Recorder iOS.
    ///   - deviceName: Label for the source (e.g. "AirDrop").
    func importLocalFile(at fileURL: URL, deviceName: String) async throws -> MobileImportResult {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attrs?[.size] as? NSNumber)?.int64Value
        let createdAt = (attrs?[.creationDate] as? Date)
            ?? Self.timestamp(fromFilename: fileURL.lastPathComponent)
            ?? Date()

        let asset = AVURLAsset(url: fileURL)
        let durationSeconds: Double? = try? await {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : nil
        }()
        let dualByChannelCount = (try? await Self.hasTwoAudioChannels(asset)) ?? false

        let info = MobileRecordingInfo(
            id: UUID().uuidString,
            filename: fileURL.lastPathComponent,
            durationSeconds: durationSeconds,
            sizeBytes: sizeBytes,
            recordedAt: createdAt,
            isDualChannel: dualByChannelCount
        )

        // Stage into mobile-inbox so the importer owns the file lifecycle.
        try FileManager.default.createDirectory(at: StorageLayout.mobileInboxURL, withIntermediateDirectories: true)
        let stagingURL = StorageLayout.mobileInboxURL.appendingPathComponent(fileURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try? FileManager.default.removeItem(at: stagingURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: stagingURL)

        // AirDrop may deliver a co-located `<stem>.meta.json` sidecar next to the
        // original file — pass its bytes through if present.
        let sidecarCandidate = fileURL.deletingPathExtension().appendingPathExtension("meta.json")
        let sidecarData = try? Data(contentsOf: sidecarCandidate)

        return try await importRecording(stagingURL: stagingURL, info: info, deviceName: deviceName, sidecarData: sidecarData)
    }

    // MARK: - Private helpers

    private static func convertToM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        await session.export()
        if let error = session.error { throw error }
    }

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

    /// Parses the `yyyyMMdd_HHmmss` timestamp embedded in the Clio filename
    /// convention (`<title>_yyyyMMdd_HHmmss.<ext>`). Returns nil if absent.
    private static func timestamp(fromFilename filename: String) -> Date? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard let match = stem.range(of: #"\d{8}_\d{6}"#, options: .regularExpression) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(stem[match]))
    }

    /// True when the asset's first audio track carries two channels — a
    /// best-effort dual-channel signal for M4A files where the WAV marker is
    /// no longer present after compression.
    private static func hasTwoAudioChannels(_ asset: AVURLAsset) async throws -> Bool {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return false }
        let descriptions = try await track.load(.formatDescriptions)
        for description in descriptions {
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                return basic.pointee.mChannelsPerFrame >= 2
            }
        }
        return false
    }
}
