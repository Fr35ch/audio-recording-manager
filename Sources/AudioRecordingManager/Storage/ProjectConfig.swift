// ProjectConfig.swift
// AudioRecordingManager
//
// Per-project configuration: Teams destination channels, neutral code
// format, and compliance confirmation state.
//
// Stored inside `AppState.currentProject` (persisted to `state/app.json`).
// The researcher sets this once when starting a project; it persists
// across sessions until they switch projects.
//
// See: US-FM-13, US-FM-14, US-FM-15, US-FM-16,
//      FILE_MANAGEMENT_AND_TEAMS_SYNC.md §Egress + §Compliance

import Foundation

// MARK: - Channel reference

/// Identifies a private Teams channel for upload. The researcher or IT
/// provides these values when configuring a project. ARM never creates
/// channels — it only uploads to channels that already exist.
struct TeamsChannelRef: Codable, Equatable {
    /// Display name shown in the ARM UI (e.g. "Studie Bærekraft Q2")
    var displayName: String
    /// Teams team ID (GUID from M365 admin / Graph)
    var teamId: String
    /// Private channel ID within the team (GUID)
    var channelId: String

    /// When the channel was created in M365 (if known). Used for the
    /// 24-hour backup-exclusion propagation check. `nil` if unknown —
    /// ARM shows a soft warning rather than blocking.
    var channelCreatedAt: Date?
}

// MARK: - Project config

struct ProjectConfig: Codable, Equatable {
    /// Human-readable project name (e.g. "Brukerinnsikt Bærekraft 2026")
    var projectName: String

    /// Private channel for audio, transcripts, anonymized transcripts, and analysis.
    var studyChannel: TeamsChannelRef?

    /// Separate private channel for consent forms (more restricted access).
    var consentChannel: TeamsChannelRef?

    /// Prefix format for neutral participant codes. Default "D" → D01, D02, ...
    /// The researcher can change this per project (e.g. "T" for T01, T02).
    var neutralCodePrefix: String

    /// When this configuration was saved. Used for audit trail.
    var configuredAt: Date

    /// When the compliance checklist was acknowledged for this project.
    /// `nil` means the checklist has not been confirmed — upload is blocked.
    var complianceConfirmedAt: Date?

    /// Counter for auto-incrementing neutral codes (D01, D02, ...).
    /// Incremented each time a new recording gets a neutral code assigned.
    var nextNeutralCodeNumber: Int

    init(
        projectName: String = "",
        studyChannel: TeamsChannelRef? = nil,
        consentChannel: TeamsChannelRef? = nil,
        neutralCodePrefix: String = "D",
        configuredAt: Date = Date(),
        complianceConfirmedAt: Date? = nil,
        nextNeutralCodeNumber: Int = 1
    ) {
        self.projectName = projectName
        self.studyChannel = studyChannel
        self.consentChannel = consentChannel
        self.neutralCodePrefix = neutralCodePrefix
        self.configuredAt = configuredAt
        self.complianceConfirmedAt = complianceConfirmedAt
        self.nextNeutralCodeNumber = nextNeutralCodeNumber
    }

    // MARK: - Computed

    /// True when both channels are configured and the project has a name.
    var isConfigured: Bool {
        !projectName.isEmpty && studyChannel != nil
    }

    /// True when the compliance checklist has been acknowledged.
    var isComplianceConfirmed: Bool {
        complianceConfirmedAt != nil
    }

    /// True when uploads can proceed (configured + compliance confirmed).
    var isReadyForUpload: Bool {
        isConfigured && isComplianceConfirmed
    }

    /// Next neutral code string (e.g. "D01", "D02").
    var nextNeutralCode: String {
        String(format: "%@%02d", neutralCodePrefix, nextNeutralCodeNumber)
    }

    /// Generates and increments the neutral code counter.
    mutating func assignNextNeutralCode() -> String {
        let code = nextNeutralCode
        nextNeutralCodeNumber += 1
        return code
    }
}
