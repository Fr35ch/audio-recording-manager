import Foundation

/// Sidecar model written by Clio Recorder iOS alongside each transferred M4A.
/// Absence of this file, or `diarization_required == true`, routes to the
/// existing probabilistic diarization path.
struct ClioMeta: Codable {
    let diarizationRequired: Bool
    let channelAssignment: ChannelAssignment?
    let recordingSource: String?
    let armVersion: String?

    struct ChannelAssignment: Codable {
        let left: String   // e.g. "INTERVJUER"
        let right: String  // e.g. "INFORMANT"
    }

    /// Defaults to INTERVJUER/INFORMANT when `channelAssignment` is absent.
    var resolvedLeft: String { channelAssignment?.left ?? "INTERVJUER" }
    var resolvedRight: String { channelAssignment?.right ?? "INFORMANT" }

    enum CodingKeys: String, CodingKey {
        case diarizationRequired = "diarization_required"
        case channelAssignment = "channel_assignment"
        case recordingSource = "recording_source"
        case armVersion = "arm_version"
    }
}

extension ClioMeta {
    /// Loads the sidecar for the given audio file URL.
    /// The sidecar sits at `<stem>.meta.json` alongside the audio file.
    /// Returns nil if the file doesn't exist or can't be decoded.
    static func load(for audioFileURL: URL) -> ClioMeta? {
        let sidecarURL = audioFileURL
            .deletingPathExtension()
            .appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return try? JSONDecoder().decode(ClioMeta.self, from: data)
    }
}
