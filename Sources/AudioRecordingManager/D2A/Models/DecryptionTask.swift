// DecryptionTask.swift
// AudioRecordingManager / D2A
//
// In-memory tracking record for one D2A → recording import. The bridge
// service appends one of these per import attempt; views observe the
// array to render progress and final state.

import Foundation

struct DecryptionTask: Identifiable, Equatable {
    enum Status: Equatable {
        case queued
        case copying          // copying d2a into VM shared folder
        case decrypting       // VM is processing, polling for status
        case importing        // copying decrypted audio into recording store
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    let file: D2AFile
    var status: Status
    var progress: Double
    var error: String?

    /// Set when the recording has been registered in `RecordingStore`.
    var recordingId: UUID?

    /// Set after the VM places the decrypted file in the shared output
    /// folder. The bridge then copies it into the recording folder.
    var decryptedAudioPath: URL?

    init(
        id: UUID = UUID(),
        file: D2AFile,
        status: Status = .queued,
        progress: Double = 0,
        error: String? = nil,
        recordingId: UUID? = nil,
        decryptedAudioPath: URL? = nil
    ) {
        self.id = id
        self.file = file
        self.status = status
        self.progress = progress
        self.error = error
        self.recordingId = recordingId
        self.decryptedAudioPath = decryptedAudioPath
    }

    var isTerminal: Bool {
        switch status {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}
