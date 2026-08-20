import Foundation
import AppKit

@MainActor
class StartupCoordinator: ObservableObject {
    @Published var phase: StartupPhase = .systemChecks
    @Published var completedCheckIndex: Int = -1
    @Published var systemRequirements: [SystemRequirement] = []
    @Published var dependencyManager = DependencyManager()
    @Published var isComplete = false
    @Published var statusMessage = ""

    enum StartupPhase: Equatable {
        case systemChecks
        case dependencies
        case modelLoading
        case complete
        case failed(String)
    }

    func runStartupSequence() async {
        // Phase 1: Synchronous system checks
        phase = .systemChecks
        let requirements = SystemRequirementChecker.runAll()
        systemRequirements = requirements

        for (i, req) in requirements.enumerated() {
            completedCheckIndex = i
            statusMessage = "Sjekker \(req.name)…"
            try? await Task.sleep(nanoseconds: 900_000_000)  // 900ms per check
            if !req.passed {
                SystemRequirementChecker.showFatalAlert(for: req)
                return
            }
        }

        // Phase 2: Dependency checks
        phase = .dependencies
        await dependencyManager.runAll()

        if let failed = dependencyManager.firstFailedCheck {
            if case .failed(let msg) = dependencyManager.checkResults[failed] ?? .pending {
                phase = .failed(msg)
                return
            }
        }

        // Phase 3: Prepare transcription runtime and large model.
        phase = .modelLoading
        statusMessage = "Laster NB-Whisper Large…"
        await TranscriptionService.shared.setupIfNeeded()
        await TranscriptionService.shared.refreshInstallationState()
        do {
            try await TranscriptionService.shared.ensureModelAvailable(.large, announce: true)
            statusMessage = "NB-Whisper Large er lastet ned"
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // Phase 4: Complete
        phase = .complete
        statusMessage = "Klar"
        try? await Task.sleep(nanoseconds: 3_000_000_000)  // 1s for bars to settle + 2s display
        isComplete = true
    }

    func retry() async {
        guard let failed = dependencyManager.firstFailedCheck else { return }
        phase = .dependencies
        await dependencyManager.retryFrom(failed)
        if dependencyManager.firstFailedCheck == nil {
            phase = .complete
            statusMessage = "Klar"
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 1s for bars to settle + 2s display
            isComplete = true
        }
    }
}
