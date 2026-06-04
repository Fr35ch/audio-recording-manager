import Foundation

enum DependencyCheck: Int, CaseIterable {
    case pythonVenv = 0
    case transcribeVenv = 1
    case whisperModel = 2
    case ollamaRunning = 3
    case llmModelLoaded = 4
    case auditLog = 5
    case allClear = 6
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

    /// The currently configured LLM model, read from UserDefaults.
    private var selectedLLMModel: LLMModel {
        LLMModel.from(storedValue: UserDefaults.standard.string(forKey: "analysis.llmModel"))
    }

    func runAll() async {
        for check in DependencyCheck.allCases {
            currentCheck = check
            checkResults[check] = .running
            statusMessage = statusText(for: check)

            do {
                let timeoutSecs: TimeInterval = check == .ollamaRunning ? 30
                    : check == .llmModelLoaded ? 600   // pull can take minutes
                    : 15
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
                let timeoutSecs: TimeInterval = check == .ollamaRunning ? 30
                    : check == .llmModelLoaded ? 600
                    : 15
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
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let venv = support.appendingPathComponent("AudioRecordingManager/no-transcribe-venv/bin/python3")
            guard FileManager.default.fileExists(atPath: venv.path) else {
                throw DependencyError.checkFailed("no-transcribe venv ikke funnet. Sett opp transkripsjon i innstillinger.")
            }

        case .transcribeVenv:
            let navt = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Github/no-transcribe/navt.py")
            guard FileManager.default.fileExists(atPath: navt.path) else {
                throw DependencyError.checkFailed("navt.py ikke funnet på ~/Github/no-transcribe/navt.py")
            }

        case .whisperModel:
            let hfCache = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
            let exists = (try? FileManager.default.contentsOfDirectory(atPath: hfCache.path))?
                .contains(where: { $0.contains("nb-whisper") }) ?? false
            if !exists {
                throw DependencyError.checkFailed("NB-Whisper-modell ikke funnet i cache. Transkriber en fil for å laste ned.")
            }

        case .ollamaRunning:
            if await isOllamaRunning() { return }
            if let binary = findOllama() {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = ["serve"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
            } else {
                return  // Ollama not installed — analysis optional
            }
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if await isOllamaRunning() { return }
            }
            return  // didn't come up — not fatal

        case .llmModelLoaded:
            // Just verify Ollama is reachable. Model download is done via
            // the in-app "Hent modell" button in settings — not at startup.
            guard await isOllamaRunning() else { return }
            return

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

    private func isOllamaRunning() async -> Bool {
        guard let url = URL(string: "http://localhost:11434") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        let response = try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse
        return response?.statusCode == 200
    }

    private func findOllama() -> String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama"]
            .first { FileManager.default.fileExists(atPath: $0) }
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
        case .ollamaRunning:   return "Starter Ollama…"
        case .llmModelLoaded:  return "Sjekker språkmodell…"
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
