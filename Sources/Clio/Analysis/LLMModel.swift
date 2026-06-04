// LLMModel.swift
// Clio
//
// Catalogue of supported local LLM models. All models run via Ollama
// at localhost:11434. Beta models require `beta.enabled` = true in
// UserDefaults before they are shown in the settings picker.

import Foundation

// MARK: - Model catalogue

enum LLMModel: String, CaseIterable, Identifiable, Codable {
    case qwen3_8b     = "qwen3:8b"
    case borealis4b   = "hf.co/NbAiLab/borealis-4b-gguf"
    case borealis12b  = "hf.co/NbAiLab/borealis-12b-gguf"

    var id: String { rawValue }

    /// The Ollama model identifier used in API calls and `ollama list`.
    /// For HuggingFace-sourced models this is the local name created via `ollama create`.
    var ollamaId: String {
        switch self {
        case .qwen3_8b:    return "qwen3:8b"
        case .borealis4b:  return "borealis-4b"
        case .borealis12b: return "borealis-12b"
        }
    }

    /// Direct GGUF download URL from HuggingFace (nil for models pulled via Ollama Hub).
    /// Q4_K_M is the standard quality/size tradeoff.
    var directGGUFUrl: URL? {
        switch self {
        case .qwen3_8b:
            return nil
        case .borealis4b:
            return URL(string: "https://huggingface.co/NbAiLab/borealis-4b-gguf/resolve/main/borealis-4b-Q4_K_M.gguf")
        case .borealis12b:
            return URL(string: "https://huggingface.co/NbAiLab/borealis-12b-gguf/resolve/main/borealis-12b-Q4_K_M.gguf")
        }
    }

    /// Short display name shown in the UI.
    var displayName: String {
        switch self {
        case .qwen3_8b:    return "Qwen3 8B"
        case .borealis4b:  return "Borealis 4B"
        case .borealis12b: return "Borealis 12B"
        }
    }

    /// Approximate RAM requirement (quantized GGUF).
    var estimatedRAM: String {
        switch self {
        case .qwen3_8b:    return "~6 GB"
        case .borealis4b:  return "~4 GB"
        case .borealis12b: return "~8 GB"
        }
    }

    /// Norwegian description shown in the picker.
    var modelDescription: String {
        switch self {
        case .qwen3_8b:
            return "Standard. God generell kvalitet på norsk og engelsk."
        case .borealis4b:
            return "Ny norsk modell fra Nasjonalbiblioteket. Anbefalt for norske intervjuer. Rask og lett."
        case .borealis12b:
            return "Stor norsk modell fra Nasjonalbiblioteket. Høyere kvalitet, men krever mer minne og tid."
        }
    }

    /// True for models only shown when the beta programme is enabled.
    var isBeta: Bool {
        switch self {
        case .qwen3_8b:    return false
        case .borealis4b:  return true
        case .borealis12b: return true
        }
    }

    /// Whether the model requires the user to accept the NB-license before use.
    var requiresNBLicense: Bool {
        switch self {
        case .qwen3_8b:    return false
        case .borealis4b:  return true
        case .borealis12b: return true
        }
    }

    // MARK: - Helpers

    /// The default stable model for new installations.
    static let defaultModel: LLMModel = .qwen3_8b

    /// Models visible to a given user based on beta enrolment.
    static func available(betaEnabled: Bool) -> [LLMModel] {
        allCases.filter { betaEnabled || !$0.isBeta }
    }

    /// Initialise from a raw UserDefaults string. Falls back to the default
    /// model so a stored value from an older version never causes a crash.
    static func from(storedValue: String?) -> LLMModel {
        guard let raw = storedValue, let model = LLMModel(rawValue: raw) else {
            return .defaultModel
        }
        return model
    }
}
