import Foundation
import AppKit

class SystemRequirementChecker {
    static func runAll() -> [SystemRequirement] {
        return [
            checkAppleSilicon(),
            checkRAM(),
            checkMacOSVersion(),
            checkNativeModels()
        ]
    }

    static func checkAppleSilicon() -> SystemRequirement {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let machineStr = String(cString: machine)
        let passed = machineStr.contains("arm") || machineStr.contains("Apple")
        return SystemRequirement(
            name: "Apple Silicon",
            minimumValue: "arm64",
            actualValue: machineStr,
            passed: passed,
            recommendation: passed ? nil : "Clio krever Apple Silicon (M1/M2/M3/M4). Intel Mac støttes ikke."
        )
    }

    static func checkRAM() -> SystemRequirement {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / 1_073_741_824
        let passed = gb >= 16
        return SystemRequirement(
            name: "RAM",
            minimumValue: "16 GB",
            actualValue: String(format: "%.0f GB", gb),
            passed: passed,
            recommendation: passed ? nil : "Øk RAM til minimum 16 GB for stabil drift av NB-Whisper og SpaCy."
        )
    }

    static func checkMacOSVersion() -> SystemRequirement {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let passed = version.majorVersion >= 14
        let actual = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return SystemRequirement(
            name: "macOS",
            minimumValue: "14.0 (Sonoma)",
            actualValue: actual,
            passed: passed,
            recommendation: passed ? nil : "Oppdater til macOS Sonoma 14 eller nyere via Systeminnstillinger → Programvareoppdatering."
        )
    }

    /// Verifies the bundled native transcription (whisper.cpp) and
    /// anonymization (CoreML BERT NER) models are present in the app
    /// bundle. Replaces the old Python interpreter/venv check — both
    /// pipelines now run fully in-process, no external runtime needed.
    static func checkNativeModels() -> SystemRequirement {
        let transcriptionOK = WhisperCppEngine.isBundled
        let anonymizerOK = BertNERDetector.isAvailable
        let passed = transcriptionOK && anonymizerOK
        let actual: String
        if passed {
            actual = "NB-Whisper + anonymiseringsmodell er innebygd"
        } else {
            var missing: [String] = []
            if !transcriptionOK { missing.append("NB-Whisper") }
            if !anonymizerOK { missing.append("anonymiseringsmodell") }
            actual = "Mangler: \(missing.joined(separator: ", "))"
        }
        return SystemRequirement(
            name: "Innebygde modeller",
            minimumValue: "Bunt med appen",
            actualValue: actual,
            passed: passed,
            recommendation: passed ? nil : "Prøv å installere appen på nytt — modellfiler mangler i appbunten."
        )
    }

    static func showFatalAlert(for requirement: SystemRequirement) {
        let alert = NSAlert()
        alert.messageText = "Systemkrav ikke oppfylt"
        alert.informativeText = """
        \(requirement.name): \(requirement.actualValue)
        Krav: \(requirement.minimumValue)

        \(requirement.recommendation ?? "")
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Avslutt")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
