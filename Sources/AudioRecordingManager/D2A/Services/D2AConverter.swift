// D2AConverter.swift
// AudioRecordingManager / D2A
//
// Local-side helpers for the D2A → recording pipeline. The actual audio
// decryption happens inside the Windows VM (Olympus SDK), so this file
// is intentionally thin: it handles validation, sanitised path building,
// and the eventual file copy from the VM shared output folder into the
// `RecordingStore` audio folder.

import Foundation

enum D2AConverter {

    /// File extension we recognise as D2A audio. Olympus DS-9500 and
    /// related Olympus dictation devices emit files with this extension.
    static let fileExtension = "d2a"

    /// Cheap pre-flight check before calling the VM service. Returns
    /// `false` for missing files, directories, zero-byte files, or files
    /// without the `.d2a` extension.
    static func isPlausibleD2A(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == fileExtension else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists, !isDir.boolValue else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        return size > 0
    }

    /// Builds the destination URL inside the VM shared input folder.
    /// Strips path separators from the filename so a maliciously named
    /// file on the SD card can't escape into the parent folder.
    static func sharedFolderInputURL(for file: D2AFile, config: VMServiceConfig) -> URL {
        let inputDir = config.sharedFolderPath.appendingPathComponent("input")
        let safeName = sanitise(filename: file.name)
        return inputDir.appendingPathComponent(safeName)
    }

    /// Builds the URL where the VM should have written the decrypted
    /// audio. The VM tells us the filename in its `DecryptResponse`; this
    /// only joins it onto the shared output folder.
    static func sharedFolderOutputURL(filename: String, config: VMServiceConfig) -> URL {
        let outputDir = config.sharedFolderPath.appendingPathComponent("output")
        return outputDir.appendingPathComponent(sanitise(filename: filename))
    }

    /// Copies the decrypted audio from the VM shared output folder to the
    /// recording's `audio.m4a` slot. The destination's parent directory
    /// is created by `RecordingStore.create`, so this only handles the
    /// file copy.
    static func copyDecryptedAudio(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw D2ABridgeError.fileNotFound(source)
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// Best-effort cleanup of the input/output files in the VM shared
    /// folder once a task is terminal. Errors are swallowed because
    /// failing here should not abort an otherwise successful import.
    static func cleanupSharedFolder(for file: D2AFile, decryptedAudio: URL?, config: VMServiceConfig) {
        let fm = FileManager.default
        let input = sharedFolderInputURL(for: file, config: config)
        try? fm.removeItem(at: input)
        if let decryptedAudio { try? fm.removeItem(at: decryptedAudio) }
    }

    // MARK: - Private

    private static func sanitise(filename: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:")
        return filename.components(separatedBy: illegal).joined(separator: "_")
    }
}
