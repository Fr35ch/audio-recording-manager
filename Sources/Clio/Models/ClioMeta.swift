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

    /// Writes this sidecar as `<stem>.meta.json` next to the given audio file.
    func write(for audioFileURL: URL) throws {
        let sidecarURL = audioFileURL
            .deletingPathExtension()
            .appendingPathExtension("meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: sidecarURL, options: .atomic)
    }

    /// Default RØDE dual-channel sidecar (INTERVJUER left / INFORMANT right).
    static func rodeDualChannelDefault() -> ClioMeta {
        ClioMeta(
            diarizationRequired: false,
            channelAssignment: ChannelAssignment(left: "INTERVJUER", right: "INFORMANT"),
            recordingSource: "ios_rode_wireless_micro",
            armVersion: nil)
    }

    /// Decodes a ClioMeta from raw sidecar bytes received over a transfer.
    static func decode(from data: Data) -> ClioMeta? {
        try? JSONDecoder().decode(ClioMeta.self, from: data)
    }
}
