import Foundation

// MARK: - Step status

enum StepStatus: String, Codable {
    case notStarted
    case inProgress
    case completed
    case failed
}

// MARK: - Per-step state

struct ProcessingStepState: Codable {
    var status: StepStatus = .notStarted
    var errorMessage: String? = nil
    var completedAt: Date? = nil
}

// MARK: - Per-file processing state

struct RecordingProcessingState: Codable {
    var transcription = ProcessingStepState()
    var diarization  = ProcessingStepState()
    var analysis     = ProcessingStepState()
}

// MARK: - Processing step enum

enum ProcessingStep {
    case transcription
    case diarization
    case analysis
}

// MARK: - Cache

/// Thread-safe, disk-backed store for processing state keyed by audio file path.
final class ProcessingStateCache {
    static let shared = ProcessingStateCache()
    private init() { loadFromDisk() }

    private let lock = NSLock()
    private var store: [String: RecordingProcessingState] = [:]
    private var analysisStore: [String: AnalysisResult] = [:]

    // MARK: Processing state

    func state(for path: String) -> RecordingProcessingState {
        lock.lock(); defer { lock.unlock() }
        return store[path] ?? RecordingProcessingState()
    }

    func setStep(_ step: ProcessingStep, status: StepStatus, for path: String, error: String? = nil) {
        lock.lock()
        var s = store[path] ?? RecordingProcessingState()
        switch step {
        case .transcription:
            s.transcription.status = status
            s.transcription.errorMessage = error
            if status == .completed { s.transcription.completedAt = Date() }
            // Re-transcribing invalidates downstream diarization state
            if status == .completed {
                s.diarization = ProcessingStepState()
            }
        case .diarization:
            s.diarization.status = status
            s.diarization.errorMessage = error
            if status == .completed { s.diarization.completedAt = Date() }
        case .analysis:
            s.analysis.status = status
            s.analysis.errorMessage = error
            if status == .completed { s.analysis.completedAt = Date() }
        }
        store[path] = s
        lock.unlock()
        saveToDisk()
    }

    // MARK: Analysis result

    func storeAnalysisResult(_ result: AnalysisResult, for path: String) {
        lock.lock()
        analysisStore[path] = result
        lock.unlock()
        saveAnalysisToDisk(result, for: path)
    }

    func analysisResult(for path: String) -> AnalysisResult? {
        lock.lock()
        if let cached = analysisStore[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        // Disk fallback
        let url = analysisFileURL(for: path)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url),
              let result = try? decoder.decode(AnalysisResult.self, from: data)
        else { return nil }
        lock.lock()
        analysisStore[path] = result
        lock.unlock()
        return result
    }

    func hasAnalysis(for path: String) -> Bool {
        analysisResult(for: path) != nil
    }

    // MARK: Disk persistence

    private var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AudioRecordingManager")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("processing-state.json")
    }

    private func analysisFileURL(for audioPath: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AudioRecordingManager/analysis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(stem).json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let decoded = try? JSONDecoder().decode([String: RecordingProcessingState].self, from: data)
        else { return }
        store = decoded
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }

    private func saveAnalysisToDisk(_ result: AnalysisResult, for path: String) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(result) else { return }
        try? data.write(to: analysisFileURL(for: path), options: .atomic)
    }
}
