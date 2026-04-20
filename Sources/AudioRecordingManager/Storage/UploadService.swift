// UploadService.swift
// AudioRecordingManager
//
// Protocol for uploading artifacts to Teams/SharePoint. The real Graph API
// implementation plugs in when OAuth is available (Phase 1). Until then,
// the stub logs the attempt and returns a "not yet available" error.
//
// See: US-FM-09, FILE_MANAGEMENT_AND_TEAMS_SYNC.md §Egress

import Foundation

// MARK: - Upload result

struct UploadResult {
    let graphItemId: String
    let remoteName: String
}

// MARK: - Protocol

protocol UploadServiceProtocol {
    /// Upload a single file to the specified Teams channel.
    func upload(
        localURL: URL,
        remoteName: String,
        channel: TeamsChannelRef
    ) async throws -> UploadResult
}

// MARK: - Stub (Phase 0)

/// Placeholder implementation that blocks all uploads until the Graph API
/// client is ready. Logs the attempt for debugging.
struct StubUploadService: UploadServiceProtocol {
    func upload(
        localURL: URL,
        remoteName: String,
        channel: TeamsChannelRef
    ) async throws -> UploadResult {
        print("⚠️ Upload not available: \(remoteName) → \(channel.displayName) (Graph API not yet configured)")
        throw UploadError.notConfigured
    }
}

enum UploadError: LocalizedError {
    case notConfigured
    case noNeutralCode
    case noProjectConfigured
    case complianceNotConfirmed
    case channelTooNew(hoursOld: Int)
    case graphError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Opplasting er ikke tilgjengelig ennå — Graph API-konfigurasjonen mangler."
        case .noNeutralCode:
            return "Deltakerkoden er ikke satt for dette opptaket. Sett en deltakerkode før opplasting."
        case .noProjectConfigured:
            return "Prosjektkonfigurasjonen er ikke satt opp. Konfigurer prosjektet i innstillingene."
        case .complianceNotConfirmed:
            return "Samsvarskravene er ikke bekreftet. Bekreft kravene under prosjektinnstillinger."
        case .channelTooNew(let hours):
            return "Kanalen er under 24 timer gammel (\(hours) timer). Vent til backup-ekskluderingen er propagert."
        case .graphError(let msg):
            return "Opplastingsfeil: \(msg)"
        }
    }
}

// MARK: - Upload coordinator

/// Orchestrates the pre-upload checks and delegates the actual upload
/// to the configured `UploadServiceProtocol` implementation.
final class UploadCoordinator {
    static let shared = UploadCoordinator()

    /// Swap this to a real Graph implementation when OAuth is ready.
    var service: UploadServiceProtocol = StubUploadService()

    private init() {}

    /// Validates all preconditions, generates remote names, then uploads
    /// each artifact for the given recording.
    func uploadRecording(id: UUID) async throws {
        let state = AppStateStore.load()

        // Check project is configured
        guard let project = state.currentProject, project.isConfigured else {
            throw UploadError.noProjectConfigured
        }

        // Check compliance confirmed
        guard project.isComplianceConfirmed else {
            throw UploadError.complianceNotConfirmed
        }

        // Check neutral code
        guard let meta = try RecordingStore.shared.load(id: id) else { return }
        guard let neutralCode = meta.neutralCode, !neutralCode.isEmpty else {
            throw UploadError.noNeutralCode
        }

        // Check channel age (24-hour rule)
        if let studyChannel = project.studyChannel,
           let createdAt = studyChannel.channelCreatedAt {
            let hoursSinceCreation = Int(Date().timeIntervalSince(createdAt) / 3600)
            if hoursSinceCreation < 24 {
                throw UploadError.channelTooNew(hoursOld: hoursSinceCreation)
            }
        }

        // Generate remote names and upload each artifact
        guard let studyChannel = project.studyChannel else { return }
        let artifacts = UploadNamingService.remoteNames(for: meta, neutralCode: neutralCode)

        for (artifactType, localURL, remoteName) in artifacts {
            // Queue audit event
            AuditLogger.shared.log(.uploadQueued, payload: [
                "recordingId": .string(id.uuidString),
                "artifact": .string(artifactType.rawValue),
                "remoteName": .string(remoteName),
            ])

            do {
                let result = try await service.upload(
                    localURL: localURL,
                    remoteName: remoteName,
                    channel: studyChannel
                )

                // Update sidecar with upload result
                _ = try? RecordingStore.shared.updateMeta(id: id) { m in
                    switch artifactType {
                    case .audio:
                        m.upload.audio.status = .uploaded
                        m.upload.audio.uploadedAt = Date()
                        m.upload.audio.graphItemId = result.graphItemId
                        m.upload.audio.remoteName = remoteName
                    case .transcript:
                        m.upload.transcript.status = .uploaded
                        m.upload.transcript.uploadedAt = Date()
                        m.upload.transcript.graphItemId = result.graphItemId
                        m.upload.transcript.remoteName = remoteName
                    default:
                        break
                    }
                }

                AuditLogger.shared.log(.uploadCompleted, payload: [
                    "recordingId": .string(id.uuidString),
                    "artifact": .string(artifactType.rawValue),
                    "remoteName": .string(remoteName),
                    "graphItemId": .string(result.graphItemId),
                ])
            } catch {
                AuditLogger.shared.log(.uploadFailed, payload: [
                    "recordingId": .string(id.uuidString),
                    "artifact": .string(artifactType.rawValue),
                    "error": .string(error.localizedDescription),
                ])
                throw error
            }
        }
    }
}
