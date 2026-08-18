import Foundation
import SwiftUI

// MARK: - SetupPhase

/// Overall phase of the first-run setup wizard.
enum SetupPhase: Equatable {
    case checking
    case running
    case complete
    case failed(String)
}

// MARK: - SetupItemID

/// Identifies a single step in the setup wizard.
enum SetupItemID: String, Hashable {
    case nbWhisper  = "nb_whisper"
    case spacy      = "spacy"
    case ollama     = "ollama"
    case ollamaModel = "ollama_model"
}

// MARK: - SetupItemStatus

/// Status of a single setup step.
enum SetupItemStatus: Equatable {
    case pending
    case running
    case done
    case failed(String)
    case skipped

    var isDone: Bool {
        switch self {
        case .done, .skipped: return true
        default: return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - SetupItem

/// A single line item in the first-run setup wizard.
struct SetupItem: Identifiable {
    let id: SetupItemID
    var title: String
    var status: SetupItemStatus
    var progress: Double   // 0.0 … 1.0; -1.0 = indeterminate
    var detail: String
}

// MARK: - SetupFlowCoordinator

/// Orchestrates the first-run download wizard.
///
/// Show `SetupFlowView` whenever `SetupFlowCoordinator.isRequired` returns
/// `true`. Call `run()` to start all downloads in sequence.
@MainActor
final class SetupFlowCoordinator: ObservableObject {
    @Published var phase: SetupPhase = .checking
    @Published var items: [SetupItem] = [
        SetupItem(id: .nbWhisper, title: "NB-Whisper (transkripsjon)", status: .pending, progress: -1, detail: ""),
        SetupItem(id: .spacy, title: "spaCy nb_core_news_lg (NLP-modell)", status: .pending, progress: -1, detail: ""),
        SetupItem(id: .ollama, title: "Ollama (lokal AI)", status: .pending, progress: -1, detail: ""),
        SetupItem(id: .ollamaModel, title: "qwen3:8b (språkmodell)", status: .pending, progress: -1, detail: ""),
    ]

    // MARK: - Static helpers

    /// `true` when any required component is missing and the wizard must be shown.
    static var isRequired: Bool {
        // 1. Bundled Python interpreter must be present.
        guard PythonRuntime.isEmbedded else { return true }

        // 2. NB-Whisper model cache must exist inside HF_HOME.
        let hfHome = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Clio/models")
        let whisperCacheDir = hfHome.appendingPathComponent("hub")
        let hasWhisper = (try? FileManager.default.contentsOfDirectory(atPath: whisperCacheDir.path))?
            .contains { $0.contains("NB-Whisper") || $0.contains("nb-whisper") || $0.contains("NbAiLab") } ?? false
        guard hasWhisper else { return true }

        if AppFeatures.analysisEnabled {
            // 3. Ollama must be reachable (ollama binary present on disk).
            guard ollamaPath != nil else { return true }

            // 4. qwen3:8b must appear in `ollama list`.
            guard isOllamaModelPresent("qwen3:8b") else { return true }
        }

        return false
    }

    /// Path to the `ollama` binary, or `nil` if not found.
    static var ollamaPath: String? {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Returns `true` if `name` appears in the output of `ollama list`.
    private static func isOllamaModelPresent(_ name: String) -> Bool {
        guard let ollama = ollamaPath else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ollama)
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return false
        }
        p.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains(name)
    }

    // MARK: - Run

    /// Orchestrates all setup steps in sequence. Safe to call multiple times
    /// (each item is checked for completion before being (re-)run).
    func run() async {
        phase = .running
        AuditLogger.shared.log(eventType: "setupFlowStarted", payload: [:])

        await runNBWhisper()
        await runSpacy()
        if AppFeatures.analysisEnabled {
            await runOllama()
            await runOllamaModel()
        } else {
            update(.ollama, status: .skipped, detail: "Analyse deaktivert")
            update(.ollamaModel, status: .skipped, detail: "Analyse deaktivert")
        }

        let anyFailed = items.contains { $0.status.isFailed }
        if anyFailed {
            let msg = items.compactMap { item -> String? in
                if case .failed(let e) = item.status { return "\(item.title): \(e)" }
                return nil
            }.joined(separator: "; ")
            phase = .failed(msg)
        } else {
            phase = .complete
        }
    }

    // MARK: - Step: NB-Whisper

    private func runNBWhisper() async {
        let itemID = SetupItemID.nbWhisper

        // Idempotency: check HF cache
        let hfHome = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Clio/models")
        let hubDir = hfHome.appendingPathComponent("hub")
        let alreadyPresent = (try? FileManager.default.contentsOfDirectory(atPath: hubDir.path))?
            .contains { $0.contains("NB-Whisper") || $0.contains("nb-whisper") || $0.contains("NbAiLab") } ?? false

        if alreadyPresent {
            update(itemID, status: .skipped, detail: "Allerede lastet ned")
            AuditLogger.shared.log(eventType: "setupItemCompleted",
                                   payload: ["item": .string(itemID.rawValue), "skipped": .bool(true)])
            return
        }

        update(itemID, status: .running, detail: "Laster ned NB-Whisper Large …")

        guard PythonRuntime.isEmbedded else {
            let msg = "Innebygd Python ikke funnet"
            update(itemID, status: .failed(msg), detail: msg)
            AuditLogger.shared.log(eventType: "setupItemFailed",
                                   payload: ["item": .string(itemID.rawValue), "error": .string(msg)])
            return
        }

        // Use huggingface_hub to pull the NbAiLab/nb-whisper-large model
        let downloadCode = """
import os
os.environ['HF_HOME'] = '\(hfHome.path)'
from huggingface_hub import snapshot_download
snapshot_download(repo_id='NbAiLab/nb-whisper-large')
print('OK')
"""
        let p = PythonRuntime.process(module: "__main__", arguments: [])
        p.executableURL = PythonRuntime.interpreter
        p.arguments = ["-c", downloadCode]

        // Override HF_HOME in the process environment
        var env = p.environment ?? ProcessInfo.processInfo.environment
        env["HF_HOME"] = hfHome.path
        p.environment = env

        await runTrackedProcess(p, itemID: itemID)
    }

    // MARK: - Step: spaCy model

    private func runSpacy() async {
        let itemID = SetupItemID.spacy

        guard PythonRuntime.isEmbedded else {
            update(itemID, status: .skipped, detail: "Innebygd Python ikke tilgjengelig")
            return
        }

        // Idempotency: check via spacy info
        let infoResult = try? PythonRuntime.run(
            code: "import spacy; spacy.load('nb_core_news_lg'); print('OK')"
        )
        if infoResult == "OK" {
            update(itemID, status: .skipped, detail: "Allerede installert")
            AuditLogger.shared.log(eventType: "setupItemCompleted",
                                   payload: ["item": .string(itemID.rawValue), "skipped": .bool(true)])
            return
        }

        update(itemID, status: .running, detail: "Laster ned nb_core_news_lg …")
        let p = PythonRuntime.process(module: "spacy", arguments: ["download", "nb_core_news_lg"])
        await runTrackedProcess(p, itemID: itemID)
    }

    // MARK: - Step: Ollama binary check

    private func runOllama() async {
        let itemID = SetupItemID.ollama

        if SetupFlowCoordinator.ollamaPath != nil {
            update(itemID, status: .done, detail: "Ollama funnet")
            AuditLogger.shared.log(eventType: "setupItemCompleted",
                                   payload: ["item": .string(itemID.rawValue), "skipped": .bool(false)])
        } else {
            let msg = "Ollama er ikke installert. Last ned fra https://ollama.com."
            update(itemID, status: .failed(msg), detail: msg)
            AuditLogger.shared.log(eventType: "setupItemFailed",
                                   payload: ["item": .string(itemID.rawValue), "error": .string(msg)])
        }
    }

    // MARK: - Step: Ollama model pull

    private func runOllamaModel() async {
        let itemID = SetupItemID.ollamaModel

        guard let ollama = SetupFlowCoordinator.ollamaPath else {
            update(itemID, status: .skipped, detail: "Ollama ikke installert — hopper over")
            return
        }

        // Idempotency: check ollama list
        if SetupFlowCoordinator.isOllamaModelPresent("qwen3:8b") {
            update(itemID, status: .skipped, detail: "Allerede lastet ned")
            AuditLogger.shared.log(eventType: "setupItemCompleted",
                                   payload: ["item": .string(itemID.rawValue), "skipped": .bool(true)])
            return
        }

        update(itemID, status: .running, detail: "Laster ned qwen3:8b …")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ollama)
        p.arguments = ["pull", "qwen3:8b"]

        await runTrackedProcess(p, itemID: itemID)
    }

    // MARK: - Shared process runner

    /// Runs a process, streaming stderr to the item's `detail` field.
    /// Marks the item `.done` on exit 0, `.failed` otherwise.
    private func runTrackedProcess(_ p: Process, itemID: SetupItemID) async {
        let stderrPipe = Pipe()
        p.standardError = stderrPipe
        p.standardOutput = Pipe()

        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !chunk.isEmpty
            else { return }
            Task { @MainActor [weak self] in
                self?.update(itemID, detail: chunk)
            }
        }

        do {
            try p.run()
        } catch {
            stderrHandle.readabilityHandler = nil
            let msg = error.localizedDescription
            update(itemID, status: .failed(msg), detail: msg)
            AuditLogger.shared.log(eventType: "setupItemFailed",
                                   payload: ["item": .string(itemID.rawValue), "error": .string(msg)])
            return
        }

        // Await completion off the main actor
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                p.waitUntilExit()
                cont.resume()
            }
        }

        stderrHandle.readabilityHandler = nil

        if p.terminationStatus == 0 {
            update(itemID, status: .done, detail: "Ferdig")
            AuditLogger.shared.log(eventType: "setupItemCompleted",
                                   payload: ["item": .string(itemID.rawValue), "skipped": .bool(false)])
        } else {
            let msg = "Prosessen avsluttet med kode \(p.terminationStatus)"
            update(itemID, status: .failed(msg), detail: msg)
            AuditLogger.shared.log(eventType: "setupItemFailed",
                                   payload: ["item": .string(itemID.rawValue), "error": .string(msg)])
        }
    }

    // MARK: - Helpers

    private func update(_ id: SetupItemID,
                        status: SetupItemStatus? = nil,
                        progress: Double? = nil,
                        detail: String? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let s = status  { items[idx].status   = s }
        if let p = progress { items[idx].progress = p }
        if let d = detail   { items[idx].detail   = d }
    }
}

// MARK: - SetupFlowView

/// First-run wizard shown when `SetupFlowCoordinator.isRequired` is `true`.
/// All user-facing strings are in Norwegian Bokmål.
struct SetupFlowView: View {
    @StateObject private var coordinator = SetupFlowCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Første gangs oppsett")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Clio laster ned nødvendige modeller. Koble til internett og vent.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Item list
            VStack(spacing: 12) {
                ForEach(coordinator.items) { item in
                    SetupItemRow(item: item)
                }
            }

            // Phase status
            switch coordinator.phase {
            case .checking, .running:
                EmptyView()

            case .complete:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Alt er klart. Du kan starte Clio.")
                        .fontWeight(.medium)
                }
                Button("Fortsett") {
                    // Caller dismisses the sheet / window.
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            case .failed(let msg):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Noen steg feilet")
                            .fontWeight(.medium)
                    }
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    Button("Prøv igjen") {
                        Task { await coordinator.run() }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 480, minHeight: 340)
        .task {
            await coordinator.run()
        }
    }
}

// MARK: - SetupItemRow

private struct SetupItemRow: View {
    let item: SetupItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Status icon / spinner
            Group {
                switch item.status {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                case .running:
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .skipped:
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 20, alignment: .center)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)

                if item.status == .running && item.progress >= 0 {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }

                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
    }
}

// MARK: - AuditLogger extension (string-based event type)

extension AuditLogger {
    /// Logs a free-form event type string for events not yet in `AuditEventType`.
    ///
    /// Use this for setup-flow events (`setupFlowStarted`, `setupItemCompleted`,
    /// `setupItemFailed`) which are not part of the core audit event enum.
    func log(eventType: String, payload: [String: AuditValue]) {
        let event = AuditEvent(
            timestamp: Date(),
            actor: NSUserName(),
            host: Host.current().localizedName ?? "",
            eventType: eventType,
            payload: payload
        )
        // Use the private queue via the existing append path by encoding manually
        // and calling through the internal serial writer.
        //
        // We access the internal `appendEvent` indirectly by constructing the
        // event and posting it via the public log(_:) method with a proxy type.
        // Since we can't call the private queue directly from here, we replicate
        // the minimal write inline. This is safe because AuditEvent is Codable
        // and the JSONL format is additive.
        _logRaw(event)
    }

    /// Internal helper — writes an AuditEvent to the current month log.
    fileprivate func _logRaw(_ event: AuditEvent) {
        // Mirror the logic in appendEvent() — uses the same JSONL path.
        // This is intentionally minimal: the write is best-effort.
        DispatchQueue.global(qos: .utility).async {
            do {
                try StorageLayout.ensureDirectoriesExist()
            } catch {
                print("❌ AuditLogger.log(eventType:): could not ensure directories: \(error)")
                return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(event),
                  let line = String(data: data, encoding: .utf8)
            else {
                print("❌ AuditLogger.log(eventType:): failed to encode event")
                return
            }
            let logLine = (line + "\n").data(using: .utf8)!
            let url = StorageLayout.currentMonthAuditLog
            if FileManager.default.fileExists(atPath: url.path) {
                guard let fh = try? FileHandle(forWritingTo: url) else { return }
                fh.seekToEndOfFile()
                fh.write(logLine)
                try? fh.close()
            } else {
                try? logLine.write(to: url, options: .atomic)
            }
        }
    }
}
