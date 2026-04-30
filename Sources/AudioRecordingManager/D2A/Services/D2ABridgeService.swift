// D2ABridgeService.swift
// AudioRecordingManager / D2A
//
// Coordinates the D2A → recording import pipeline:
//
//   1. Verify VM service is reachable
//   2. Copy the .d2a file into the VM shared input folder
//   3. Ask the VM to decrypt (POST /api/decrypt)
//   4. Poll until the VM reports Completed or Failed
//   5. Copy the decrypted audio into a fresh RecordingStore slot
//   6. Finalise the recording (size, duration) so it appears in the UI
//
// All published state is updated on the main actor. Blocking I/O
// (file copies, AVAudioFile reads) is performed off-main via
// `Task.detached` to keep the UI responsive.

import AVFoundation
import Foundation

@MainActor
final class D2ABridgeService: ObservableObject {

    @Published var isVMAvailable: Bool = false
    @Published var lastHealthCheck: Date?
    @Published var sdkVersion: String?
    @Published var tasks: [DecryptionTask] = []
    @Published var configError: String?

    private(set) var config: VMServiceConfig?
    private var client: VMServiceClient?

    init() {
        loadConfig()
    }

    // MARK: - Configuration

    func loadConfig() {
        do {
            if let cfg = try VMServiceConfig.load() {
                self.config = cfg
                self.client = VMServiceClient(config: cfg)
                self.configError = nil
            } else {
                self.config = nil
                self.client = nil
                self.configError = "Mangler d2a-config.json"
            }
        } catch {
            self.config = nil
            self.client = nil
            self.configError = "Ugyldig d2a-config.json: \(error.localizedDescription)"
        }
    }

    // MARK: - Health

    func checkVMStatus() async {
        guard let client else {
            isVMAvailable = false
            return
        }
        do {
            let health = try await client.checkHealth()
            isVMAvailable = health.status.lowercased() == "healthy"
            sdkVersion = health.sdkVersion
            lastHealthCheck = Date()
        } catch {
            isVMAvailable = false
            sdkVersion = nil
            lastHealthCheck = Date()
        }
    }

    // MARK: - Import

    /// Import a single D2A file. Returns the new recording's UUID on
    /// success. Updates the task array as the import progresses; the UI
    /// observes that array for progress display.
    @discardableResult
    func importD2AFile(_ file: D2AFile, password: String) async throws -> UUID {
        guard let config = self.config, let client = self.client else {
            throw D2ABridgeError.notConfigured
        }

        let task = DecryptionTask(file: file, status: .queued)
        appendTask(task)

        do {
            // 1. Copy into VM shared input folder
            try ensureSharedFolderReady(config: config)
            updateTask(task.id) { $0.status = .copying }

            let sharedInput = D2AConverter.sharedFolderInputURL(for: file, config: config)
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try fm.createDirectory(
                    at: sharedInput.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: sharedInput.path) {
                    try fm.removeItem(at: sharedInput)
                }
                try fm.copyItem(at: file.path, to: sharedInput)
            }.value

            // 2. Kick off decryption
            updateTask(task.id) { $0.status = .decrypting }
            let initial = try await client.decrypt(file: file, password: password, taskId: task.id)
            try await pollUntilTerminal(taskId: task.id, initial: initial, client: client, config: config)

            // 3. After polling, the task should have decryptedAudioPath set
            guard let snapshot = currentTask(task.id),
                  let decryptedAudio = snapshot.decryptedAudioPath else {
                throw D2ABridgeError.decryptionFailed("Manglet utdatafil fra VM")
            }

            // 4. Import into RecordingStore
            updateTask(task.id) { $0.status = .importing }
            let recordingId = try await registerRecording(
                from: decryptedAudio,
                originalName: file.displayName
            )

            updateTask(task.id) {
                $0.recordingId = recordingId
                $0.status = .completed
                $0.progress = 1.0
            }

            // 5. Best-effort cleanup
            D2AConverter.cleanupSharedFolder(
                for: file,
                decryptedAudio: decryptedAudio,
                config: config
            )

            return recordingId
        } catch {
            updateTask(task.id) {
                $0.status = .failed
                $0.error = error.localizedDescription
            }
            // Cleanup whatever we wrote into the shared folder
            if let cfg = self.config {
                let snapshot = currentTask(task.id)
                D2AConverter.cleanupSharedFolder(
                    for: file,
                    decryptedAudio: snapshot?.decryptedAudioPath,
                    config: cfg
                )
            }
            throw error
        }
    }

    func cancel(taskId: UUID) {
        updateTask(taskId) { task in
            guard !task.isTerminal else { return }
            task.status = .cancelled
        }
    }

    func clearCompleted() {
        tasks.removeAll { $0.isTerminal }
    }

    // MARK: - Polling

    private func pollUntilTerminal(
        taskId: UUID,
        initial: DecryptResponse,
        client: VMServiceClient,
        config: VMServiceConfig
    ) async throws {
        var latest = initial
        while true {
            // Honour cancellation
            if currentTask(taskId)?.status == .cancelled {
                throw CancellationError()
            }

            switch latest.status.lowercased() {
            case "completed":
                let outputName = latest.outputFile ?? ""
                let outputURL = D2AConverter.sharedFolderOutputURL(
                    filename: outputName,
                    config: config
                )
                updateTask(taskId) {
                    $0.progress = 1.0
                    $0.decryptedAudioPath = outputURL
                }
                return
            case "failed":
                throw D2ABridgeError.decryptionFailed(latest.error)
            default:
                let progress = max(0, min(100, latest.progress))
                updateTask(taskId) { $0.progress = Double(progress) / 100.0 }
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
            latest = try await client.checkStatus(taskId: taskId)
        }
    }

    // MARK: - RecordingStore integration

    private func registerRecording(from decryptedAudio: URL, originalName: String) async throws -> UUID {
        let store = RecordingStore.shared
        let handle = try store.create(displayName: originalName)

        try await Task.detached(priority: .userInitiated) {
            try D2AConverter.copyDecryptedAudio(from: decryptedAudio, to: handle.audioURL)
        }.value

        let (duration, size) = await readAudioStats(at: handle.audioURL)
        try store.finalize(id: handle.id, durationSeconds: duration, sizeBytes: size)

        return handle.id
    }

    nonisolated private func readAudioStats(at url: URL) async -> (duration: Double?, size: Int64?) {
        await Task.detached(priority: .userInitiated) {
            let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            let duration: Double?
            if let file = try? AVAudioFile(forReading: url) {
                let rate = file.processingFormat.sampleRate
                duration = rate > 0 ? Double(file.length) / rate : nil
            } else {
                duration = nil
            }
            return (duration, size)
        }.value
    }

    // MARK: - Task array helpers

    private func appendTask(_ task: DecryptionTask) {
        tasks.append(task)
    }

    private func currentTask(_ id: UUID) -> DecryptionTask? {
        tasks.first { $0.id == id }
    }

    private func updateTask(_ id: UUID, _ mutate: (inout DecryptionTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var copy = tasks[index]
        mutate(&copy)
        tasks[index] = copy
    }

    private func ensureSharedFolderReady(config: VMServiceConfig) throws {
        let root = config.sharedFolderPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            throw D2ABridgeError.sharedFolderUnreachable(root)
        }
    }
}
