import Foundation

// MARK: - Model size

enum TranscriptionModel: String, CaseIterable, Identifiable, Codable {
    case tiny
    case base
    case medium
    case large

    var id: String { rawValue }

    /// Norwegian display name shown in the UI.
    var displayName: String {
        switch self {
        case .tiny:   return "Liten"
        case .base:   return "Basis"
        case .medium: return "Medium"
        case .large:  return "Stor"
        }
    }

    /// Approximate RAM requirement for the model.
    var estimatedRAM: String {
        switch self {
        case .tiny:   return "~1 GB"
        case .base:   return "~2 GB"
        case .medium: return "~4 GB"
        case .large:  return "~8 GB"
        }
    }

    /// Norwegian description shown in the settings picker.
    var modelDescription: String {
        switch self {
        case .tiny:
            return "Raskest, lavest nøyaktighet. Egnet for testing og korte klipp."
        case .base:
            return "Rask med akseptabel nøyaktighet. God for korte intervjuer."
        case .medium:
            return "God balanse mellom hastighet og nøyaktighet."
        case .large:
            return "Anbefalt. Høyest nøyaktighet. Krever mer behandlingstid."
        }
    }
}
