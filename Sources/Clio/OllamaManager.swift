import Foundation

// MARK: - OllamaManager

/// Manages the lifecycle of a local Ollama server process.
/// Used by TranscriptionService to auto-start Ollama before analysis.
final class OllamaManager {
    static let shared = OllamaManager()
    private init() {}

    private var ollamaProcess: Process?

    /// Returns true if Ollama responds at localhost:11434.
    func isRunning() -> Bool {
        let url = URL(string: "http://localhost:11434")!
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        var isUp = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            isUp = (response as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        sem.wait()
        return isUp
    }

    /// Path to the ollama binary, or nil if not installed.
    var ollamaBinaryPath: String? {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/usr/bin/ollama",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// True if the ollama binary exists on disk.
    var isInstalled: Bool { ollamaBinaryPath != nil }

    /// Returns the installed Ollama version string (e.g. "0.24.0"), or nil.
    func installedVersion() -> String? {
        guard let binary = ollamaBinaryPath else { return nil }
        let process = Process()
        process.launchPath = binary
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // "ollama version is 0.24.0"
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        return parts.last
    }

    /// How Ollama is installed — determines correct upgrade instructions.
    enum InstallMethod {
        case app      // Ollama.app → symlink at /usr/local/bin/ollama
        case brew     // Homebrew → /opt/homebrew/bin/ollama
        case other
    }

    var installMethod: InstallMethod {
        guard let path = ollamaBinaryPath else { return .other }
        if path == "/opt/homebrew/bin/ollama" { return .brew }
        // /usr/local/bin/ollama symlinks into Ollama.app on most app installs
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
        if resolved.contains("Ollama.app") { return .app }
        return .other
    }

    /// Returns true if the installed Ollama version supports hf.co/ model pulls.
    /// Minimum known-good version is 0.5.0.
    func supportsHuggingFacePull() -> Bool {
        guard let version = installedVersion() else { return false }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        // 0.x where x < 5 is too old; 1.x+ is fine
        if parts[0] > 0 { return true }
        return parts[1] >= 5
    }

    /// Start ollama serve in background. Returns immediately; Ollama takes ~2s to be ready.
    func startServer() {
        guard let binary = ollamaBinaryPath else { return }
        guard !isRunning() else { return }
        let process = Process()
        process.launchPath = binary
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        ollamaProcess = process
    }

    /// Wait up to `timeout` seconds for Ollama to become available.
    /// Returns true if it came up within the deadline.
    func waitUntilReady(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // MARK: - Model pull

    enum PullError: LocalizedError {
        case notInstalled
        case pullFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Ollama er ikke installert."
            case .pullFailed(let msg):
                return "Kunne ikke laste ned modellen: \(msg)"
            }
        }
    }

    /// Check whether a model is already available locally.
    /// Calls `ollama list` and scans output for the model ID.
    func isModelAvailable(_ modelId: String) -> Bool {
        guard let binary = ollamaBinaryPath else { return false }
        let process = Process()
        process.launchPath = binary
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Model names in `ollama list` output are colon-separated; do a simple substring check.
        return output.localizedCaseInsensitiveContains(modelId)
    }

    /// Pull a model from Ollama Hub (or HuggingFace via `hf.co/` prefix).
    /// Streams stderr lines to `onProgress`. Throws `PullError` on failure.
    /// Must be called off the main thread (uses synchronous Process).
    func pull(modelId: String, onProgress: @escaping (String) -> Void) throws {
        guard let binary = ollamaBinaryPath else {
            throw PullError.notInstalled
        }
        let process = Process()
        process.launchPath = binary
        process.arguments = ["pull", modelId]
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        var lastErrorLine = ""
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else { return }
            lastErrorLine = line
            onProgress(line)
        }

        try process.run()
        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Drain any remaining stderr that the readability handler may not have caught.
        let remainingData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if let remaining = String(data: remainingData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !remaining.isEmpty {
            lastErrorLine = remaining
        }

        // Ollama 0.24.x exits with code 0 even on pull errors, so also check stderr content.
        let failed = process.terminationStatus != 0 || lastErrorLine.hasPrefix("Error:")
        if failed {
            if lastErrorLine.contains("realm host") || lastErrorLine.contains("does not match") {
                throw PullError.pullFailed("Ollama er for gammel til å laste ned HuggingFace-modeller. Oppdater Ollama til versjon 0.5 eller nyere.")
            }
            let detail = lastErrorLine.isEmpty ? "Ukjent feil" : lastErrorLine
            throw PullError.pullFailed(detail)
        }
    }
}
