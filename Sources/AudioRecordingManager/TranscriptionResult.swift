import Foundation

// MARK: - Word-level timing

struct TranscriptionWord: Codable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double
}

// MARK: - Segment

struct TranscriptionSegment: Codable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    let speaker: String
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
    let diarizationRun: Bool?
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
    let numSpeakers: Int
    let segments: [TranscriptionSegment]
    let metadata: TranscriptionResultMetadata
}
