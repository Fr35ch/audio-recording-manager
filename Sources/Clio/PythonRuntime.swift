import Foundation

// MARK: - PythonRuntime

/// Resolves the python-build-standalone interpreter embedded in the app bundle
/// and provides factory methods for creating subprocess objects that are
/// correctly isolated from any system Python installation.
///
/// When the app is distributed as a notarized DMG, `embed-python.sh` copies
/// a self-contained CPython interpreter to `Clio.app/Contents/Resources/python/`.
/// `PythonRuntime` is the single authoritative source for the interpreter path —
/// all service code should query `isEmbedded` before deciding how to invoke Python.
enum PythonRuntime {

    /// Root of the bundled CPython tree (…/Clio.app/Contents/Resources/python).
    static var home: URL {
        Bundle.main.resourceURL!.appendingPathComponent("python")
    }

    /// Path to the `python3` binary inside the bundled interpreter tree.
    static var interpreter: URL {
        home.appendingPathComponent("bin/python3")
    }

    /// `true` when the bundled interpreter is present on disk.
    ///
    /// Use this as a feature-flag gate:
    /// ```swift
    /// if PythonRuntime.isEmbedded {
    ///     // use PythonRuntime.process(...)
    /// } else {
    ///     // fall back to venv / PATH resolution
    /// }
    /// ```
    static var isEmbedded: Bool {
        FileManager.default.fileExists(atPath: interpreter.path)
    }

    // MARK: - Process factory

    /// Returns a `Process` configured to run the bundled interpreter with
    /// `python3 -m <module> <arguments>`.
    ///
    /// The process environment is fully isolated from the calling process:
    /// - `PYTHONHOME` is set to the bundled interpreter root.
    /// - `PYTHONPATH` is removed (avoids contamination from any system site-packages).
    /// - `HF_HOME` is pointed at `~/Library/Application Support/Clio/models` so
    ///   Hugging Face model caches live in a predictable, app-specific location.
    /// - `METAL_DEVICE_WRAPPER_TYPE` is stripped (prevents Metal validation
    ///   assertion failures inherited from Xcode's debugger environment).
    /// - `TOKENIZERS_PARALLELISM` is set to `"false"` to suppress a common
    ///   fork-safety warning from the `tokenizers` library.
    ///
    /// - Parameters:
    ///   - module: The Python module name (e.g. `"no_transcribe"`).
    ///   - arguments: Additional CLI arguments passed after `-m <module>`.
    static func process(module: String, arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = interpreter
        p.arguments = ["-m", module] + arguments

        var env = ProcessInfo.processInfo.environment
        env["PYTHONHOME"] = home.path
        env.removeValue(forKey: "PYTHONPATH")
        env["HF_HOME"] = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Clio/models").path
        env.removeValue(forKey: "METAL_DEVICE_WRAPPER_TYPE")
        env["TOKENIZERS_PARALLELISM"] = "false"
        p.environment = env
        return p
    }

    // MARK: - Convenience runner

    /// Runs the bundled interpreter with `-c <code>` and returns stdout as a
    /// trimmed UTF-8 string.
    ///
    /// Stdout and stderr are merged into a single pipe so that Python
    /// tracebacks are included in the thrown error when the process fails.
    ///
    /// - Throws: `PythonRuntimeError.notEmbedded` if no bundled interpreter is
    ///   present, or `PythonRuntimeError.nonZeroExit` when the process exits
    ///   with a non-zero status code.
    static func run(code: String) throws -> String {
        guard isEmbedded else {
            throw PythonRuntimeError.notEmbedded
        }
        let p = Process()
        p.executableURL = interpreter
        p.arguments = ["-c", code]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONHOME"] = home.path
        env.removeValue(forKey: "PYTHONPATH")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw PythonRuntimeError.nonZeroExit(p.terminationStatus, output)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - PythonRuntimeError

enum PythonRuntimeError: LocalizedError {
    case notEmbedded
    case nonZeroExit(Int32, String)

    var errorDescription: String? {
        switch self {
        case .notEmbedded:
            return "Innebygd Python-miljø ikke funnet i appbunten"
        case .nonZeroExit(let code, let output):
            return "Python avsluttet med kode \(code): \(output)"
        }
    }
}
