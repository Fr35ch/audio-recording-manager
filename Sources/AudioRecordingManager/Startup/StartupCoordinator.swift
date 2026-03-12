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
            try? await Task.sleep(nanoseconds: 120_000_000)  // 120ms per check for visual effect
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

        // Phase 3: Complete
        phase = .complete
        statusMessage = "Audio Recording Manager er klar"
        try? await Task.sleep(nanoseconds: 1_200_000_000)  // 1.2s display
        isComplete = true
    }

    func retry() async {
        guard let failed = dependencyManager.firstFailedCheck else { return }
        phase = .dependencies
        await dependencyManager.retryFrom(failed)
        if dependencyManager.firstFailedCheck == nil {
            phase = .complete
            statusMessage = "Audio Recording Manager er klar"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isComplete = true
        }
    }
}
