// LegacyStorageScanner.swift
// AudioRecordingManager
//
// Detects pre-Phase-0 data on the Desktop so `StorageMigrator` knows whether
// there is anything to migrate. This is the ONLY file in the codebase that is
// permitted to reference `FileManager.default.urls(for: .desktopDirectory, ...)` —
// the Desktop is no longer a supported data location outside of migration.

import Foundation

struct LegacyStorageReport: Equatable {
    /// `~/Desktop/lydfiler/` — legacy audio folder. `nil` if the folder does
    /// not exist at all.
    var audioFolder: URL?
    /// `~/Desktop/tekstfiler/` — legacy transcript folder. `nil` if the folder
    /// does not exist at all.
    var transcriptFolder: URL?
    /// Audio files found under `audioFolder`. Includes `.m4a` only.
    var audioFiles: [URL]
    /// Transcript files found under `transcriptFolder`. Includes `.txt` only.
    var transcriptFiles: [URL]

    var hasAnything: Bool {
        !audioFiles.isEmpty || !transcriptFiles.isEmpty
    }

    var totalFileCount: Int {
        audioFiles.count + transcriptFiles.count
    }
}

enum LegacyStorageScanner {

    /// Desktop path to the legacy audio folder. Resolved at call time rather
    /// than stored, so unit tests can monkey with the home directory.
    static var legacyAudioFolder: URL {
        FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("lydfiler", isDirectory: true)
    }

    static var legacyTranscriptFolder: URL {
        FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("tekstfiler", isDirectory: true)
    }

    /// Scans the legacy folders and returns a structured report. Missing
    /// folders, permission errors, and empty folders all yield a valid report
    /// with empty arrays — the caller decides what to do.
    static func scan() -> LegacyStorageReport {
        let fm = FileManager.default
        let audio = legacyAudioFolder
        let text = legacyTranscriptFolder

        let audioExists = fm.fileExists(atPath: audio.path)
        let textExists = fm.fileExists(atPath: text.path)

        let audioFiles = audioExists ? collectFiles(in: audio, extension: "m4a") : []
        let transcriptFiles = textExists ? collectFiles(in: text, extension: "txt") : []

        return LegacyStorageReport(
            audioFolder: audioExists ? audio : nil,
            transcriptFolder: textExists ? text : nil,
            audioFiles: audioFiles,
            transcriptFiles: transcriptFiles
        )
    }

    /// Recursive scan for files with a given extension. We walk subfolders
    /// because the existing `FolderManager` supports a subfolder structure
    /// under `~/Desktop/lydfiler/`, so migration must not miss files there.
    private static func collectFiles(in root: URL, extension ext: String) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            guard url.pathExtension.lowercased() == ext.lowercased() else { continue }
            results.append(url)
        }
        return results
    }
}
