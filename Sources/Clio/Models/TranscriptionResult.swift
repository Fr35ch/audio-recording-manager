import Foundation

// MARK: - Word-level timing

struct TranscriptionWord: Codable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double
}

// MARK: - Segment

struct TranscriptionSegment: Codable, Identifiable {
    let id: Int
    let start: Double
    let end: Double
    var text: String
    /// Set initially by NB-Whisper (placeholder "SPEAKER_0") then updated
    /// by the diarization pass that runs after transcription.
    /// `SpeakerAlignment.attachSpeakers(to:using:)` overwrites it.
    var speaker: String
    let confidence: Double
    let words: [TranscriptionWord]

    /// Formats a segment start time as "m:ss", e.g. `75` → `"1:15"`.
    /// Shared between the transcript editor's inline display and
    /// transcript exports so timestamps read identically everywhere.
    static func formatTimestamp(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Converts a raw speaker identifier (`"SPEAKER_0"`, `"INTERVJUER"`, …)
    /// into the short label shown in the UI (`"T1"`, `"Intervjuer"`, …).
    /// Shared between the transcript editor's inline display and
    /// transcript exports so speaker labels read identically everywhere.
    static func shortSpeakerLabel(_ speaker: String) -> String {
        if speaker.hasPrefix("SPEAKER_"), let num = Int(speaker.dropFirst(8)) {
            return "T\(num + 1)"
        }
        switch speaker {
        case "INTERVJUER": return "Intervjuer"
        case "INFORMANT":  return "Informant"
        default: return speaker
        }
    }
}

// MARK: - Metadata

struct TranscriptionResultMetadata: Codable {
    let inputFile: String
    let processingTimeSeconds: Double
    let modelVariant: String
    let computeType: String
    let device: String
    /// Set to `true` after the diarization pass runs. Persisted in JSON
    /// so we can detect "transcribed but not yet diarised" recordings.
    var diarizationRun: Bool?
}

// MARK: - Top-level result (mirrors no-transcribe JSON contract v1.0)
//
// Decoded with JSONDecoder().keyDecodingStrategy = .convertFromSnakeCase
// so "duration_seconds" → durationSeconds, "num_speakers" → numSpeakers, etc.

struct TranscriptionResult: Codable {
    let version: String
    let model: String
    let language: String
    let durationSeconds: Double
    /// Updated by the diarization pass once it completes — count of
    /// unique speakers the model identified.
    var numSpeakers: Int
    var segments: [TranscriptionSegment]
    /// `var` so the diarization pass can flip `diarizationRun = true`
    /// without rebuilding the whole struct.
    var metadata: TranscriptionResultMetadata
}
