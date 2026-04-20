// UploadNamingService.swift
// AudioRecordingManager
//
// Generates neutral-code filenames for Teams upload.
// Format: <neutralCode>_<YYYYMMDD>_<artifactType>.<ext>
//
// See: US-FM-16, FILE_MANAGEMENT_AND_TEAMS_SYNC.md §Naming on Teams

import Foundation

enum ArtifactType: String {
    case audio
    case transcript
    case transcriptAnonymized = "transcript_anonymized"
    case analysis
}

enum UploadNamingService {

    /// Generates the Teams filename for an artifact.
    ///
    /// Example: `D01_20260414_audio.m4a`
    ///
    /// - Parameters:
    ///   - neutralCode: participant code (e.g. "D01")
    ///   - createdAt: recording creation date (used for YYYYMMDD)
    ///   - artifactType: which artifact
    ///   - fileExtension: original file extension (e.g. "m4a", "txt", "json")
    /// - Returns: the generated filename, safe for Teams upload
    static func remoteName(
        neutralCode: String,
        createdAt: Date,
        artifactType: ArtifactType,
        fileExtension: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = formatter.string(from: createdAt)
        return "\(neutralCode)_\(dateStr)_\(artifactType.rawValue).\(fileExtension)"
    }

    /// Generates all remote names for a recording's artifacts.
    /// Only includes artifacts that actually exist on disk.
    static func remoteNames(
        for meta: RecordingMeta,
        neutralCode: String
    ) -> [(artifactType: ArtifactType, localURL: URL, remoteName: String)] {
        var results: [(ArtifactType, URL, String)] = []

        // Audio
        let audioURL = StorageLayout.recordingFolder(id: meta.id)
            .appendingPathComponent(meta.audio.filename)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            let ext = (meta.audio.filename as NSString).pathExtension
            results.append((.audio, audioURL, remoteName(
                neutralCode: neutralCode, createdAt: meta.createdAt,
                artifactType: .audio, fileExtension: ext.isEmpty ? "m4a" : ext
            )))
        }

        // Transcript
        let txtURL = StorageLayout.transcriptURL(id: meta.id)
        if FileManager.default.fileExists(atPath: txtURL.path) {
            results.append((.transcript, txtURL, remoteName(
                neutralCode: neutralCode, createdAt: meta.createdAt,
                artifactType: .transcript, fileExtension: "txt"
            )))
        }

        // Anonymized transcript
        let anonURL = StorageLayout.anonymizedTranscriptURL(id: meta.id)
        if FileManager.default.fileExists(atPath: anonURL.path) {
            results.append((.transcriptAnonymized, anonURL, remoteName(
                neutralCode: neutralCode, createdAt: meta.createdAt,
                artifactType: .transcriptAnonymized, fileExtension: "txt"
            )))
        }

        // Analysis
        let analysisURL = StorageLayout.analysisURL(id: meta.id)
        if FileManager.default.fileExists(atPath: analysisURL.path) {
            results.append((.analysis, analysisURL, remoteName(
                neutralCode: neutralCode, createdAt: meta.createdAt,
                artifactType: .analysis, fileExtension: "json"
            )))
        }

        return results
    }
}
