import Foundation

// MARK: - Error types

enum TranscriptionError: LocalizedError {
    case notInstalled
    case timeout
    case processFailed(String)
    case invalidOutput
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return """
            no-transcribe er ikke installert. Installer via innstillingspanelet, \
            eller manuelt med:
              pip install git+https://github.com/Fr35ch/no-transcribe.git
            """
        case .timeout:
            return "Transkripsjon tok for lang tid. Prøv igjen eller velg en mindre modell."
        case .processFailed(let message):
            return "Transkripsjon feilet: \(message)"
        case .invalidOutput:
            return "Uventet svar fra transkripsjonsprosessen"
        case .cancelled:
            return "Transkripsjon avbrutt"
        }
    }
}

// MARK: - Progress stage

enum TranscriptionStage: String {
    case idle
    case loadingModel = "loading_model"
    case transcribing
    case aligning
    case diarizing
    case analyzing
    case complete

    /// Norwegian display string for the current stage.
    var displayName: String {
        switch self {
        case .idle:         return ""
        case .loadingModel: return "Laster modell..."
        case .transcribing: return "Transkriberer..."
        case .aligning:     return "Justerer tidsstempler..."
        case .diarizing:    return "Identifiserer talere..."
        case .analyzing:    return "Analyserer..."
        case .complete:     return "Ferdig"
        }
    }
}

// MARK: - In-memory transcription cache

/// Holds TranscriptionResult objects keyed by audio file path for the duration of the app session.
/// Results are added when transcription completes and restored when the user navigates back to a file.
final class TranscriptionCache {
    static let shared = TranscriptionCache()
    private var cache: [String: TranscriptionResult] = [:]
    private let lock = NSLock()

    private init() {}

    func store(_ result: TranscriptionResult, for path: String) {
        lock.lock()
        cache[path] = result
        lock.unlock()
    }

    func result(for path: String) -> TranscriptionResult? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    func hasResult(for path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[path] != nil
    }
}

// MARK: - Service

/// Calls the no-transcribe CLI via a subprocess.
///
/// Threading model:
///   - All async methods dispatch work to `DispatchQueue.global(qos: .userInitiated)`.
///   - Stderr is read in real-time via `readabilityHandler` for live progress updates.
///   - Stdout is read once after the process exits for the JSON result.
///   - All @Published updates happen on the main thread.
final class TranscriptionService: ObservableObject, @unchecked Sendable {
    static let shared = TranscriptionService()

    @Published var progress: Double = 0
    @Published var stage: TranscriptionStage = .idle
    @Published var diarizationProgress: Double = 0
    @Published var analysisProgress: Double = 0
    @Published var isSettingUp: Bool = false
    @Published var setupError: String? = nil
    /// Human-readable description of the current setup step (e.g. pip download lines).
    @Published var setupStageDescription: String = ""

    private var activeProcess: Process?

    private init() {}

    // MARK: - Computed paths

    /// Root of the managed venv created by `install()`.
    private var venvRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AudioRecordingManager/no-transcribe-venv")
    }

    /// Path to the navt.py script in the local no-transcribe repository.
    private var navtScriptPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Github/no-transcribe/navt.py")
    }

    /// Returns the command to invoke navt.py, shell-escaped.
    ///
    /// Uses the managed venv's Python interpreter to run navt.py directly —
    /// avoids the need to pip-install a CLI binary.
    private var noTranscribeExecutable: String {
        let python = venvRoot.appendingPathComponent("bin/python3").path
        if FileManager.default.fileExists(atPath: python)
            && FileManager.default.fileExists(atPath: navtScriptPath) {
            return "\(python.armShellEscaped) \(navtScriptPath.armShellEscaped)"
        }
        return "no-transcribe"  // fallback: resolved via login-shell PATH
    }

    // MARK: - Public API

    /// True when navt.py exists locally AND torch is installed in the managed venv.
    var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: navtScriptPath) else { return false }
        // Check that torch is present in the managed venv's site-packages
        let venvLib = venvRoot.appendingPathComponent("lib")
        guard let pythonDirs = try? FileManager.default.contentsOfDirectory(atPath: venvLib.path)
        else { return false }
        for pyDir in pythonDirs {
            let torchDir = venvLib
                .appendingPathComponent(pyDir)
                .appendingPathComponent("site-packages/torch")
            if FileManager.default.fileExists(atPath: torchDir.path) { return true }
        }
        return false
    }

    /// Transcribes an audio file. Reports real-time progress via `stage` and `progress`.
    func transcribe(
        audioFile: URL,
        speakers: Int,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String
    ) async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runSubprocess(
                        audioFile: audioFile,
                        speakers: speakers,
                        model: model,
                        verbatim: verbatim,
                        language: language
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Installs no-transcribe if not already present. Safe to call repeatedly — no-ops if installed.
    /// Intended to be called once at app launch in the background.
    func setupIfNeeded() async {
        guard !isInstalled || !venvPythonIsCompatible() else { return }
        DispatchQueue.main.async {
            self.isSettingUp = true
            self.setupError = nil
            self.setupStageDescription = ""
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .background).async {
                do {
                    try self.runInstall()
                    DispatchQueue.main.async {
                        self.isSettingUp = false
                        self.setupStageDescription = ""
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isSettingUp = false
                        self.setupStageDescription = ""
                        self.setupError = error.localizedDescription
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Creates a managed venv and installs no-transcribe from GitHub.
    func install() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.runInstall()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Upgrades no-transcribe to the latest version in the managed venv.
    func update() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.runUpdate()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Downloads (pre-caches) the given NB-Whisper model weights.
    func downloadModel(_ model: TranscriptionModel) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.runDownloadModel(model)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Terminates any running transcription process.
    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
        DispatchQueue.main.async {
            self.progress = 0
            self.stage = .idle
        }
    }

    // MARK: - Subprocess execution

    private func runSubprocess(
        audioFile: URL,
        speakers: Int,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String
    ) throws -> TranscriptionResult {
        var cmdParts = [
            noTranscribeExecutable,
            "--input", audioFile.path.armShellEscaped,
            "--format", "json",
            "--model", model.rawValue,
            "--speakers", "\(speakers)",
            "--language", language,
        ]
        if verbatim { cmdParts.append("--verbatim") }
        let cmd = cmdParts.joined(separator: " ")

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-lc", cmd]

        // Strip Metal API Validation flag inherited from Xcode's debugger environment.
        // METAL_DEVICE_WRAPPER_TYPE=1 enables strict Metal validation which causes MPS
        // shader assertion failures (validateComputeFunctionArguments) in subprocesses.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "METAL_DEVICE_WRAPPER_TYPE")
        env["TOKENIZERS_PARALLELISM"] = "false"
        task.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        activeProcess = task

        // Read stderr in real-time for progress updates.
        // fullStderrLines accumulates ALL lines so Python tracebacks appear in error messages.
        let stderrHandle = stderrPipe.fileHandleForReading
        var stderrBuffer = ""
        var fullStderrLines: [String] = []
        let bufferLock = NSLock()

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            bufferLock.lock()
            stderrBuffer += chunk
            var lines = stderrBuffer.components(separatedBy: "\n")
            stderrBuffer = lines.removeLast()  // keep last (potentially incomplete) fragment
            fullStderrLines.append(contentsOf: lines.filter { !$0.isEmpty })
            bufferLock.unlock()
            for line in lines where !line.isEmpty {
                self.handleProgressLine(line)
            }
        }

        // Read stdout in real-time to prevent pipe-buffer deadlock.
        // navt.py can emit >64 KB of JSON for long recordings; if Swift only reads stdout
        // after waitUntilExit the pipe fills up, Python's print() blocks, and they deadlock.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        var accumulatedStdout = Data()
        let stdoutLock = NSLock()

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutLock.lock()
            accumulatedStdout.append(data)
            stdoutLock.unlock()
        }

        do {
            try task.run()
        } catch {
            stderrHandle.readabilityHandler = nil
            activeProcess = nil
            throw TranscriptionError.processFailed(error.localizedDescription)
        }

        // Poll for completion (same pattern as AnonymizationService).
        // 2-hour ceiling for long recordings; typical interviews complete in minutes.
        let deadline = Date().addingTimeInterval(7200)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                stderrHandle.readabilityHandler = nil
                activeProcess = nil
                throw TranscriptionError.timeout
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        stderrHandle.readabilityHandler = nil
        stdoutHandle.readabilityHandler = nil
        activeProcess = nil

        let exitCode = task.terminationStatus

        switch exitCode {
        case 0:
            break  // success — fall through to JSON parsing
        case 3:
            throw TranscriptionError.notInstalled
        default:
            bufferLock.lock()
            var allLines = fullStderrLines
            let tail = stderrBuffer
            bufferLock.unlock()
            // Drain any remaining bytes that arrived after the last readabilityHandler call
            let extra = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            if !tail.isEmpty { allLines.append(tail) }
            allLines.append(contentsOf: extra.components(separatedBy: "\n").filter { !$0.isEmpty })
            let errText = allLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionError.processFailed(
                errText.isEmpty ? "exit code \(exitCode)" : errText
            )
        }

        // Parse stdout JSON result (already fully read by the readabilityHandler above)
        stdoutLock.lock()
        let stdoutData = accumulatedStdout
        stdoutLock.unlock()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? decoder.decode(TranscriptionResult.self, from: stdoutData) else {
            throw TranscriptionError.invalidOutput
        }

        DispatchQueue.main.async {
            self.progress = 1.0
            self.stage = .complete
        }

        return result
    }

    // MARK: - Install / Update / Download

    private func setSetupStage(_ description: String) {
        DispatchQueue.main.async { self.setupStageDescription = description }
    }

    private func runInstall() throws {
        // If a venv already exists but was built with Python < 3.10, remove it and start fresh
        if FileManager.default.fileExists(atPath: venvRoot.path) && !venvPythonIsCompatible() {
            setSetupStage("Sletter gammelt virtuelt miljø (inkompatibel Python)…")
            try? FileManager.default.removeItem(at: venvRoot)
        }

        if !FileManager.default.fileExists(atPath: venvRoot.path) {
            setSetupStage("Finner Python 3.10+…")
            let python = try findPython310Plus()
            let parent = venvRoot.deletingLastPathComponent().path.armShellEscaped
            setSetupStage("Oppretter virtuelt miljø…")
            try runShell("mkdir -p \(parent)")
            try runShell("\(python.armShellEscaped) -m venv \(venvRoot.path.armShellEscaped)")
            let pip = venvRoot.appendingPathComponent("bin/pip").path.armShellEscaped
            setSetupStage("Oppgraderer pip…")
            try runShell("\(pip) install --upgrade pip --quiet")
        }

        // Install ML dependencies directly — no pip wheel build needed.
        // torch alone is ~2 GB; first install takes 5–15 min depending on connection.
        let pip = venvRoot.appendingPathComponent("bin/pip").path.armShellEscaped
        setSetupStage("Installerer torch, transformers, numpy (torch ~2 GB, 5–15 min)…")
        try runShellWithLiveOutput(
            "\(pip) install torch torchaudio transformers numpy",
            timeout: 1800  // 30 minutes ceiling for slow connections
        )
    }

    /// Returns true if the venv's Python is 3.10 or newer.
    private func venvPythonIsCompatible() -> Bool {
        let python = venvRoot.appendingPathComponent("bin/python3").path
        guard FileManager.default.fileExists(atPath: python) else { return false }
        let task = Process()
        task.launchPath = python
        task.arguments = ["-c", "import sys; exit(0 if sys.version_info >= (3, 10) else 1)"]
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Finds the first python3.10+ executable available on this machine.
    ///
    /// Search order:
    ///   1. `which python3.xx` via login-shell (picks up pyenv shims, Homebrew in PATH, etc.)
    ///   2. Known direct paths: Homebrew (Apple Silicon + Intel), pyenv shims, conda/miniforge
    private func findPython310Plus() throws -> String {
        let versions = ["python3.13", "python3.12", "python3.11", "python3.10"]

        // 1. Login-shell PATH probe
        for name in versions {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-lc", "which \(name) 2>/dev/null"]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            task.waitUntilExit()
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty { return path }
        }

        // 2. Direct path fallback (Homebrew, pyenv, conda/miniforge)
        let home = NSHomeDirectory()
        var directCandidates: [String] = []
        for ver in versions {
            // Homebrew on Apple Silicon (/opt/homebrew) and Intel (/usr/local)
            directCandidates += [
                "/opt/homebrew/bin/\(ver)",
                "/usr/local/bin/\(ver)",
            ]
            // Homebrew versioned formula paths, e.g. /opt/homebrew/opt/python@3.11/bin/python3.11
            let shortVer = ver.replacingOccurrences(of: "python", with: "")  // "3.11"
            directCandidates += [
                "/opt/homebrew/opt/python@\(shortVer)/bin/\(ver)",
                "/usr/local/opt/python@\(shortVer)/bin/\(ver)",
            ]
        }
        // pyenv shims and a few conda/miniforge roots
        directCandidates += [
            "\(home)/.pyenv/shims/python3",
            "\(home)/miniforge3/bin/python3",
            "\(home)/opt/anaconda3/bin/python3",
            "\(home)/anaconda3/bin/python3",
            "/opt/conda/bin/python3",
        ]

        for path in directCandidates where FileManager.default.fileExists(atPath: path) {
            // Verify it's actually ≥3.10
            let task = Process()
            task.launchPath = path
            task.arguments = ["-c", "import sys; exit(0 if sys.version_info >= (3, 10) else 1)"]
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return path }
        }

        throw TranscriptionError.processFailed(
            "Python 3.10 eller nyere ble ikke funnet. Installer via: brew install python@3.11"
        )
    }

    private func runUpdate() throws {
        guard FileManager.default.fileExists(
            atPath: venvRoot.appendingPathComponent("bin/pip").path
        ) else {
            throw TranscriptionError.notInstalled
        }
        let pip = venvRoot.appendingPathComponent("bin/pip").path.armShellEscaped
        try runShell(
            "\(pip) install --upgrade git+https://github.com/Fr35ch/no-transcribe.git"
        )
    }

    private func runDownloadModel(_ model: TranscriptionModel) throws {
        let cmd = "\(noTranscribeExecutable) --download-model \(model.rawValue)"
        try runShell(cmd)
    }

    // MARK: - Generic shell helpers

    /// Runs a shell command via `/bin/sh -lc` (login shell for PATH compatibility).
    /// Polls for completion with an optional timeout to avoid hanging indefinitely.
    private func runShell(_ cmd: String, timeout: TimeInterval = 300) throws {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-lc", cmd]

        let stderrPipe = Pipe()
        task.standardError = stderrPipe

        do {
            try task.run()
        } catch {
            throw TranscriptionError.processFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                throw TranscriptionError.processFailed(
                    "Kommandoen tok for lang tid (tidsavbrudd etter \(Int(timeout / 60)) min)"
                )
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if task.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText =
                String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit code \(task.terminationStatus)"
            throw TranscriptionError.processFailed(errText)
        }
    }

    /// Runs a shell command and forwards live stdout/stderr lines to `setupStageDescription`.
    /// Used for `pip install` so the user can see download progress in the UI.
    private func runShellWithLiveOutput(_ cmd: String, timeout: TimeInterval = 1800) throws {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-lc", cmd]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        var lastErrLines = ""
        let lock = NSLock()

        // Forward non-empty lines to the UI in real time (stdout + stderr combined)
        let forward: (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let lines = chunk.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lock.lock()
                lastErrLines = trimmed
                lock.unlock()
                DispatchQueue.main.async { self.setupStageDescription = trimmed }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = forward
        stderrPipe.fileHandleForReading.readabilityHandler = forward

        do {
            try task.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw TranscriptionError.processFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                throw TranscriptionError.processFailed(
                    "Installasjon tok for lang tid (tidsavbrudd etter \(Int(timeout / 60)) min)"
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if task.terminationStatus != 0 {
            lock.lock()
            let errText = lastErrLines
            lock.unlock()
            throw TranscriptionError.processFailed(
                errText.isEmpty ? "pip exit code \(task.terminationStatus)" : errText
            )
        }
    }

    // MARK: - Diarize subprocess

    private func runDiarizeSubprocess(
        audioFile: URL,
        existingResult: TranscriptionResult,
        hfToken: String,
        speakers: Int
    ) throws -> TranscriptionResult {
        // Write existing result to a temp JSON file for --transcript-input
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("arm-transcript-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let jsonData = try encoder.encode(existingResult)
        try jsonData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let python = venvRoot.appendingPathComponent("bin/python3").path
        let navtScript = navtScriptPath
        let tempJSONPath = tempURL.path
        let cmd = "\(python.armShellEscaped) \(navtScript.armShellEscaped) --input \(audioFile.path.armShellEscaped) --transcript-input \(tempJSONPath.armShellEscaped) --format json --diarize-only --hf-token \(hfToken.armShellEscaped) --speakers \(speakers)"

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-lc", cmd]

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "METAL_DEVICE_WRAPPER_TYPE")
        env["TOKENIZERS_PARALLELISM"] = "false"
        task.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        activeProcess = task

        let stderrHandle = stderrPipe.fileHandleForReading
        var stderrBuffer = ""
        var fullStderrLines: [String] = []
        let bufferLock = NSLock()

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            bufferLock.lock()
            stderrBuffer += chunk
            var lines = stderrBuffer.components(separatedBy: "\n")
            stderrBuffer = lines.removeLast()
            fullStderrLines.append(contentsOf: lines.filter { !$0.isEmpty })
            bufferLock.unlock()
            for line in lines where !line.isEmpty {
                self.handleProgressLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        var accumulatedStdout = Data()
        let stdoutLock = NSLock()

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutLock.lock()
            accumulatedStdout.append(data)
            stdoutLock.unlock()
        }

        do {
            try task.run()
        } catch {
            stderrHandle.readabilityHandler = nil
            activeProcess = nil
            throw TranscriptionError.processFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(7200)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                stderrHandle.readabilityHandler = nil
                activeProcess = nil
                throw TranscriptionError.timeout
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        stderrHandle.readabilityHandler = nil
        stdoutHandle.readabilityHandler = nil
        activeProcess = nil

        let exitCode = task.terminationStatus

        switch exitCode {
        case 0:
            break
        case 6:
            throw TranscriptionError.processFailed(
                "Ugyldig Hugging Face-token. Sjekk HF-tokenet i innstillingene."
            )
        default:
            bufferLock.lock()
            var allLines = fullStderrLines
            let tail = stderrBuffer
            bufferLock.unlock()
            let extra = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            if !tail.isEmpty { allLines.append(tail) }
            allLines.append(contentsOf: extra.components(separatedBy: "\n").filter { !$0.isEmpty })
            let errText = allLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionError.processFailed(
                errText.isEmpty ? "exit code \(exitCode)" : errText
            )
        }

        stdoutLock.lock()
        let stdoutData = accumulatedStdout
        stdoutLock.unlock()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? decoder.decode(TranscriptionResult.self, from: stdoutData) else {
            throw TranscriptionError.invalidOutput
        }

        return result
    }

    // MARK: - Analyze subprocess

    private func runAnalyzeSubprocess(
        existingResult: TranscriptionResult,
        llmModel: String
    ) throws -> AnalysisResult {
        // Write existing result to a temp JSON file for --transcript-input
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("arm-transcript-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let jsonData = try encoder.encode(existingResult)
        try jsonData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let python = venvRoot.appendingPathComponent("bin/python3").path
        let navtScript = navtScriptPath
        let tempJSONPath = tempURL.path
        let cmd = "\(python.armShellEscaped) \(navtScript.armShellEscaped) --analyze-only --transcript-input \(tempJSONPath.armShellEscaped) --format json --llm \(llmModel.armShellEscaped)"

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-lc", cmd]

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "METAL_DEVICE_WRAPPER_TYPE")
        env["TOKENIZERS_PARALLELISM"] = "false"
        task.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        activeProcess = task

        let stderrHandle = stderrPipe.fileHandleForReading
        var stderrBuffer = ""
        var fullStderrLines: [String] = []
        let bufferLock = NSLock()

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            bufferLock.lock()
            stderrBuffer += chunk
            var lines = stderrBuffer.components(separatedBy: "\n")
            stderrBuffer = lines.removeLast()
            fullStderrLines.append(contentsOf: lines.filter { !$0.isEmpty })
            bufferLock.unlock()
            for line in lines where !line.isEmpty {
                self.handleProgressLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        var accumulatedStdout = Data()
        let stdoutLock = NSLock()

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutLock.lock()
            accumulatedStdout.append(data)
            stdoutLock.unlock()
        }

        do {
            try task.run()
        } catch {
            stderrHandle.readabilityHandler = nil
            activeProcess = nil
            throw TranscriptionError.processFailed(error.localizedDescription)
        }

        // 10-minute ceiling for LLM analysis
        let deadline = Date().addingTimeInterval(600)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                stderrHandle.readabilityHandler = nil
                activeProcess = nil
                throw TranscriptionError.timeout
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        stderrHandle.readabilityHandler = nil
        stdoutHandle.readabilityHandler = nil
        activeProcess = nil

        let exitCode = task.terminationStatus

        switch exitCode {
        case 0:
            break
        case 5:
            throw TranscriptionError.processFailed(
                "Ollama kjører ikke. Start Ollama og prøv igjen."
            )
        default:
            bufferLock.lock()
            var allLines = fullStderrLines
            let tail = stderrBuffer
            bufferLock.unlock()
            let extra = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            if !tail.isEmpty { allLines.append(tail) }
            allLines.append(contentsOf: extra.components(separatedBy: "\n").filter { !$0.isEmpty })
            let errText = allLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionError.processFailed(
                errText.isEmpty ? "exit code \(exitCode)" : errText
            )
        }

        stdoutLock.lock()
        let stdoutData = accumulatedStdout
        stdoutLock.unlock()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let result = try? decoder.decode(AnalysisResult.self, from: stdoutData) else {
            throw TranscriptionError.invalidOutput
        }

        return result
    }

    // MARK: - Public diarize/analyze API

    func diarize(
        audioFile: URL,
        existingResult: TranscriptionResult,
        hfToken: String,
        speakers: Int
    ) async throws -> TranscriptionResult {
        await MainActor.run {
            self.stage = .diarizing
            self.diarizationProgress = 0
        }
        ProcessingStateCache.shared.setStep(.diarization, status: .inProgress, for: audioFile.path)

        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let r = try self.runDiarizeSubprocess(
                            audioFile: audioFile,
                            existingResult: existingResult,
                            hfToken: hfToken,
                            speakers: speakers
                        )
                        continuation.resume(returning: r)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            TranscriptionCache.shared.store(result, for: audioFile.path)
            saveTranscriptJSON(result, audioURL: audioFile)
            ProcessingStateCache.shared.setStep(.diarization, status: .completed, for: audioFile.path)
            await MainActor.run {
                self.diarizationProgress = 1.0
                self.stage = .idle
            }
            return result
        } catch {
            ProcessingStateCache.shared.setStep(.diarization, status: .failed, for: audioFile.path,
                                                error: error.localizedDescription)
            await MainActor.run { self.stage = .idle }
            throw error
        }
    }

    func analyze(
        audioFile: URL,
        existingResult: TranscriptionResult,
        llmModel: String
    ) async throws -> AnalysisResult {
        await MainActor.run {
            self.stage = .analyzing
            self.analysisProgress = 0
        }
        ProcessingStateCache.shared.setStep(.analysis, status: .inProgress, for: audioFile.path)

        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let r = try self.runAnalyzeSubprocess(
                            existingResult: existingResult,
                            llmModel: llmModel
                        )
                        continuation.resume(returning: r)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            ProcessingStateCache.shared.storeAnalysisResult(result, for: audioFile.path)
            ProcessingStateCache.shared.setStep(.analysis, status: .completed, for: audioFile.path)
            await MainActor.run {
                self.analysisProgress = 1.0
                self.stage = .idle
            }
            return result
        } catch {
            ProcessingStateCache.shared.setStep(.analysis, status: .failed, for: audioFile.path,
                                                error: error.localizedDescription)
            await MainActor.run { self.stage = .idle }
            throw error
        }
    }

    // MARK: - Transcript JSON persistence

    func saveTranscriptJSONPublic(_ result: TranscriptionResult, audioURL: URL) {
        saveTranscriptJSON(result, audioURL: audioURL)
    }

    private func saveTranscriptJSON(_ result: TranscriptionResult, audioURL: URL) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AudioRecordingManager/transcripts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = audioURL.deletingPathExtension().lastPathComponent
        let url = dir.appendingPathComponent("\(stem).json")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? encoder.encode(result) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Progress parsing

    private func handleProgressLine(_ line: String) {
        guard
            let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stageStr = obj["stage"] as? String,
            let progressVal = obj["progress"] as? Double
        else { return }

        let newStage = TranscriptionStage(rawValue: stageStr) ?? .idle
        DispatchQueue.main.async {
            self.progress = progressVal
            self.stage = newStage
            switch newStage {
            case .diarizing:
                self.diarizationProgress = progressVal
            case .analyzing:
                self.analysisProgress = progressVal
            default:
                break
            }
        }
    }
}

// MARK: - String helper

private extension String {
    /// Shell-escapes a path by wrapping in single quotes and escaping any embedded single quotes.
    var armShellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
