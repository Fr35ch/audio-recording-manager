import Foundation

// MARK: - Error types

enum AnonymizationError: LocalizedError {
    case bridgeScriptNotFound
    case libraryNotInstalled
    case timeout
    case processFailed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .bridgeScriptNotFound:
            return "Anonymiseringsskript ikke funnet i appbunten"
        case .libraryNotInstalled:
            return """
            no-anonymizer er ikke installert. Installer via:
              pip install "no-anonymizer[ner]"
            """
        case .timeout:
            return "Anonymisering tok for lang tid (maks 30 sekunder). Prøv igjen."
        case .processFailed(let message):
            return "Anonymisering feilet: \(message)"
        case .invalidOutput:
            return "Uventet svar fra anonymiseringstjenesten"
        }
    }
}

// MARK: - Service

/// Calls the no-anonymizer Python library via a subprocess bridge script.
///
/// Threading model:
///   - `anonymize(transcript:)` is an async function; callers may await it from any context.
///   - The underlying subprocess runs on `DispatchQueue.global(qos: .userInitiated)`.
///   - Results are returned to the caller's actor context (typically MainActor in the UI).
final class AnonymizationService: @unchecked Sendable {
    static let shared = AnonymizationService()

    private init() {}

    // MARK: - Public API

    func anonymize(transcript: String) async throws -> AnonymizationResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runSubprocess(transcript: transcript)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Subprocess execution

    private func bridgeScriptURL() -> URL? {
        // 1. App bundle Resources (production)
        if let url = Bundle.main.url(forResource: "anonymize_bridge", withExtension: "py") {
            return url
        }
        // 2. Development fallback: project root Resources/
        let devPath =
            FileManager.default.currentDirectoryPath + "/Resources/anonymize_bridge.py"
        if FileManager.default.fileExists(atPath: devPath) {
            return URL(fileURLWithPath: devPath)
        }
        return nil
    }

    /// Returns the Python executable to use, preferring the no-anonymizer dev venv.
    ///
    /// Priority:
    ///   1. `~/Github/no-anonymizer/.venv/bin/python3` — local development venv
    ///   2. `python3` via login shell PATH — production / globally installed
    private func pythonExecutable() -> String {
        let candidates = [
            (NSHomeDirectory() as NSString).appendingPathComponent(
                "Github/no-anonymizer/.venv/bin/python3")
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path.armShellEscaped
        }
        return "python3"  // resolved via login-shell PATH
    }

    private func runSubprocess(transcript: String) throws -> AnonymizationResult {
        guard let scriptURL = bridgeScriptURL() else {
            throw AnonymizationError.bridgeScriptNotFound
        }

        // Write transcript to a temp file (avoids shell quoting issues with arbitrary text)
        let tmp = FileManager.default.temporaryDirectory
        let uid = UUID().uuidString
        let inputURL = tmp.appendingPathComponent("arm_anon_in_\(uid).txt")
        let outputURL = tmp.appendingPathComponent("arm_anon_out_\(uid).json")

        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try transcript.write(to: inputURL, atomically: true, encoding: .utf8)

        // Use the best available Python; login shell so Homebrew/pyenv PATH is also available
        let cmd = "\(pythonExecutable()) \(scriptURL.path.armShellEscaped) "
            + "--input \(inputURL.path.armShellEscaped) "
            + "--output \(outputURL.path.armShellEscaped)"

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-lc", cmd]

        let stderrPipe = Pipe()
        task.standardError = stderrPipe

        do {
            try task.run()
        } catch {
            throw AnonymizationError.processFailed(error.localizedDescription)
        }

        // Poll for completion with 30-second timeout
        let deadline = Date().addingTimeInterval(30)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                throw AnonymizationError.timeout
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let exitCode = task.terminationStatus

        switch exitCode {
        case 0:
            break // success — fall through to JSON parsing
        case 3:
            throw AnonymizationError.libraryNotInstalled
        default:
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText =
                String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit code \(exitCode)"
            // Try to extract the message field from the JSON error payload the bridge writes
            let humanMessage = extractBridgeErrorMessage(from: errText) ?? errText
            throw AnonymizationError.processFailed(humanMessage)
        }

        // Parse output JSON
        guard let data = try? Data(contentsOf: outputURL) else {
            throw AnonymizationError.invalidOutput
        }
        let decoder = JSONDecoder()
        guard let result = try? decoder.decode(AnonymizationResult.self, from: data) else {
            throw AnonymizationError.invalidOutput
        }
        return result
    }

    // MARK: - Helpers

    private func extractBridgeErrorMessage(from stderrText: String) -> String? {
        guard let data = stderrText.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let msg = obj["message"] as? String
        else { return nil }
        return msg
    }
}

// MARK: - String helper

private extension String {
    /// Shell-escapes a path by wrapping in single quotes and escaping any embedded single quotes.
    var armShellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
