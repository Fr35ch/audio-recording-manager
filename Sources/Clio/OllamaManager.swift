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
        return output.localizedCaseInsensitiveContains(modelId)
    }

    /// Download and register a model. For HuggingFace GGUF models, downloads the file
    /// directly (bypassing the broken hf.co redirect) then registers via `ollama create`.
    /// For standard Ollama Hub models, uses `ollama pull`.
    /// Streams progress strings to `onProgress`. Throws `PullError` on failure.
    /// Must be called off the main thread.
    func pull(model: LLMModel, onProgress: @escaping (String) -> Void) throws {
        guard let binary = ollamaBinaryPath else { throw PullError.notInstalled }

        if let ggufUrl = model.directGGUFUrl {
            try downloadGGUFAndCreate(
                url: ggufUrl,
                ollamaId: model.ollamaId,
                binary: binary,
                onProgress: onProgress
            )
        } else {
            try ollamaPull(modelId: model.ollamaId, binary: binary, onProgress: onProgress)
        }
    }

    // MARK: - Private helpers

    private func downloadGGUFAndCreate(
        url: URL,
        ollamaId: String,
        binary: String,
        onProgress: @escaping (String) -> Void
    ) throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let dest = tmpDir.appendingPathComponent("\(ollamaId).gguf")

        // Download with curl --progress-bar so we can stream simple progress lines.
        onProgress("Laster ned \(url.lastPathComponent)…")
        let curlProcess = Process()
        curlProcess.launchPath = "/usr/bin/curl"
        curlProcess.arguments = ["-L", "--progress-bar", "-o", dest.path, url.absoluteString]
        curlProcess.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        curlProcess.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            // curl --progress-bar writes lines like "###  3.2%"
            onProgress(text)
        }

        try curlProcess.run()
        curlProcess.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard curlProcess.terminationStatus == 0 else {
            throw PullError.pullFailed("Nedlastingen feilet (curl exit \(curlProcess.terminationStatus)).")
        }

        // Register the downloaded GGUF with Ollama via a temporary Modelfile.
        onProgress("Registrerer modellen i Ollama…")
        let modelfile = tmpDir.appendingPathComponent("\(ollamaId).Modelfile")
        try "FROM \(dest.path)\n".write(to: modelfile, atomically: true, encoding: .utf8)

        let createProcess = Process()
        createProcess.launchPath = binary
        createProcess.arguments = ["create", ollamaId, "-f", modelfile.path]
        let createPipe = Pipe()
        createProcess.standardOutput = createPipe
        createProcess.standardError = createPipe
        createPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            onProgress(text)
        }

        try createProcess.run()
        createProcess.waitUntilExit()
        createPipe.fileHandleForReading.readabilityHandler = nil

        // Clean up temp files regardless of outcome.
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.removeItem(at: modelfile)

        guard createProcess.terminationStatus == 0 else {
            throw PullError.pullFailed("Kunne ikke registrere modellen i Ollama.")
        }
    }

    /// Pull a model directly from Ollama Hub via `ollama pull`.
    private func ollamaPull(modelId: String, binary: String, onProgress: @escaping (String) -> Void) throws {
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

        let remainingData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if let remaining = String(data: remainingData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !remaining.isEmpty {
            lastErrorLine = remaining
        }

        let failed = process.terminationStatus != 0 || lastErrorLine.hasPrefix("Error:")
        if failed {
            let detail = lastErrorLine.isEmpty ? "Ukjent feil" : lastErrorLine
            throw PullError.pullFailed(detail)
        }
    }
}
