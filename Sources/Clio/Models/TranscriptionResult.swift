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
