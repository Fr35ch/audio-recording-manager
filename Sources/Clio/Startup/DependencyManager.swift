import Foundation

enum DependencyCheck: Int, CaseIterable {
    case pythonVenv = 0
    case transcribeVenv = 1
    case whisperModel = 2
    case auditLog = 3
    case allClear = 4
}

enum DependencyError: LocalizedError {
    case checkFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .checkFailed(let msg): return msg
        case .timeout(let name): return "\(name) tok for lang tid"
        }
    }
}

@MainActor
class DependencyManager: ObservableObject {
    @Published var currentCheck: DependencyCheck = .pythonVenv
    @Published var checkResults: [DependencyCheck: CheckStatus] = [:]
    @Published var overallProgress: Double = 0
    @Published var statusMessage: String = ""

    func runAll() async {
        for check in DependencyCheck.allCases {
            currentCheck = check
            checkResults[check] = .running
            statusMessage = statusText(for: check)

            do {
                let timeoutSecs: TimeInterval = 15
                try await withTimeout(seconds: timeoutSecs) {
                    try await self.runCheck(check)
                }
                checkResults[check] = .passed
                // Minimum dwell so each status message is readable on screen.
                try? await Task.sleep(nanoseconds: 800_000_000)  // 800ms per step
            } catch {
                checkResults[check] = .failed(error.localizedDescription)
                return  // stop on first failure
            }
            overallProgress = Double(check.rawValue + 1) / Double(DependencyCheck.allCases.count)
        }
    }

    func retryFrom(_ check: DependencyCheck) async {
        let remaining = DependencyCheck.allCases.filter { $0.rawValue >= check.rawValue }
        for c in remaining {
            checkResults[c] = .pending
        }
        for check in remaining {
            currentCheck = check
            checkResults[check] = .running
            statusMessage = statusText(for: check)
            do {
                let timeoutSecs: TimeInterval = 15
                try await withTimeout(seconds: timeoutSecs) {
                    try await self.runCheck(check)
                }
                checkResults[check] = .passed
            } catch {
                checkResults[check] = .failed(error.localizedDescription)
                return
            }
            overallProgress = Double(check.rawValue + 1) / Double(DependencyCheck.allCases.count)
        }
    }

    private func runCheck(_ check: DependencyCheck) async throws {
        switch check {
        case .pythonVenv:
            // When the app ships a bundled interpreter (DMG distribution),
            // PythonRuntime.isEmbedded is the authoritative check.
            if PythonRuntime.isEmbedded { return }
            // Developer / side-loaded fallback: look for the managed venv.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let venv = support.appendingPathComponent("AudioRecordingManager/no-transcribe-venv/bin/python3")
            guard FileManager.default.fileExists(atPath: venv.path) else {
                throw DependencyError.checkFailed("Python-miljø ikke funnet. Sett opp transkripsjon i innstillinger.")
            }

        case .transcribeVenv:
            // Embedded bundle already contains no_transcribe — trust the packager.
            if PythonRuntime.isEmbedded { return }
            // Developer fallback: accept either a venv-installed package or the
            // legacy navt.py script under ~/Github/no-transcribe/.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let venvPython = support.appendingPathComponent("AudioRecordingManager/no-transcribe-venv/bin/python3")
            let navt = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Github/no-transcribe/navt.py")
            guard FileManager.default.fileExists(atPath: venvPython.path)
                    || FileManager.default.fileExists(atPath: navt.path) else {
                throw DependencyError.checkFailed("no-transcribe-pakken ikke funnet. Sett opp transkripsjon i innstillinger.")
            }

        case .whisperModel:
            // When using the embedded interpreter, HF_HOME is set to
            // ~/Library/Application Support/Clio/models (see PythonRuntime).
            let hfCacheURL: URL
            if PythonRuntime.isEmbedded {
                hfCacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Clio/models/hub")
            } else {
                hfCacheURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache/huggingface/hub")
            }
            let exists = (try? FileManager.default.contentsOfDirectory(atPath: hfCacheURL.path))?
                .contains(where: { $0.contains("nb-whisper") }) ?? false
            if !exists {
                throw DependencyError.checkFailed("NB-Whisper-modell ikke funnet i cache. Transkriber en fil for å laste ned.")
            }

        case .auditLog:
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("AudioRecordingManager")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let test = dir.appendingPathComponent(".write_test")
            guard FileManager.default.createFile(atPath: test.path, contents: nil) else {
                throw DependencyError.checkFailed("Kan ikke skrive til applikasjonsmappe")
            }
            try? FileManager.default.removeItem(at: test)

        case .allClear:
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DependencyError.timeout("Sjekk")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func statusText(for check: DependencyCheck) -> String {
        switch check {
        case .pythonVenv:      return "Ser etter Python-miljø…"
        case .transcribeVenv:  return "Sjekker transkripsjonspakke…"
        case .whisperModel:    return "Ser etter Whisper-modell…"
        case .auditLog:        return "Klargjør revisjonsdatabase…"
        case .allClear:        return "Klar"
        }
    }

    var firstFailedCheck: DependencyCheck? {
        DependencyCheck.allCases.first {
            if case .failed = checkResults[$0] ?? .pending { return true }
            return false
        }
    }
}
