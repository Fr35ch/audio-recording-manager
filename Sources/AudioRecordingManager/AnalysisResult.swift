import Foundation

// MARK: - Analysis result (mirrors navt.py JSON contract)
//
// Decoded with JSONDecoder().keyDecodingStrategy = .convertFromSnakeCase
// so "generated_at" → generatedAt, "llm_model" → llmModel, etc.
// Date is encoded by navt.py as a Unix timestamp (Double); use .secondsSince1970.

struct AnalysisResult: Codable, Identifiable {
    let generatedAt: Date
    let llmModel: String
    let keyThemes: [String]
    let keyQuotes: [String]
    let identifiedNeeds: [String]
    let opportunities: [String]
    let rawMarkdown: String

    var id: String { llmModel + generatedAt.description }
}
