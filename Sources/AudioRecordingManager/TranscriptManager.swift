import Foundation

// MARK: - Transcript Item

struct TranscriptItem: Identifiable, Equatable, Hashable {
    let id = UUID()
    let filename: String
    let path: String
    let date: Date
    let size: Int64

    /// Filename without extension — used to match against recording stems.
    var stem: String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d. MMM, HH:mm"
        return formatter.string(from: date)
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// MARK: - Transcript Manager

/// Watches ~/Desktop/tekstfiler/ for .txt transcript files.
///
/// Follows the same DispatchSource pattern as RecordingsManager.
/// The folder is created automatically on first launch.
class TranscriptManager: ObservableObject {
    static let shared = TranscriptManager()

    @Published var transcripts: [TranscriptItem] = []

    let transcriptFolderPath: String

    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    private init() {
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        transcriptFolderPath = desktopPath.appendingPathComponent("tekstfiler").path
        createFolderIfNeeded()
        loadTranscripts()
        startWatchingFolder()
    }

    deinit {
        stopWatchingFolder()
    }

    // MARK: - Folder management

    private func createFolderIfNeeded() {
        guard !FileManager.default.fileExists(atPath: transcriptFolderPath) else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: transcriptFolderPath, withIntermediateDirectories: true)
            print("📁 Created tekstfiler folder at: \(transcriptFolderPath)")
        } catch {
            print("❌ TranscriptManager: could not create folder: \(error)")
        }
    }

    // MARK: - File watching (mirrors RecordingsManager)

    private func startWatchingFolder() {
        fileDescriptor = open(transcriptFolderPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("⚠️ TranscriptManager: could not open folder for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.reloadWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                print("📄 tekstfiler changed, reloading transcripts...")
                self?.loadTranscripts()
            }
            self?.reloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
            self?.fileDescriptor = -1
        }

        dispatchSource = source
        source.resume()
        print("👁️ Watching tekstfiler folder: \(transcriptFolderPath)")
    }

    private func stopWatchingFolder() {
        dispatchSource?.cancel()
        dispatchSource = nil
        reloadWorkItem?.cancel()
    }

    // MARK: - Load

    func loadTranscripts() {
        let fileManager = FileManager.default
        do {
            let files = try fileManager.contentsOfDirectory(atPath: transcriptFolderPath)
            var items: [TranscriptItem] = []

            for file in files {
                let filePath = (transcriptFolderPath as NSString).appendingPathComponent(file)
                let fileURL = URL(fileURLWithPath: filePath)

                guard fileURL.pathExtension.lowercased() == "txt" else { continue }

                let attrs = try fileManager.attributesOfItem(atPath: filePath)
                if let size = attrs[.size] as? Int64,
                    let date = attrs[.modificationDate] as? Date
                {
                    items.append(
                        TranscriptItem(
                            filename: file,
                            path: filePath,
                            date: date,
                            size: size
                        ))
                }
            }

            transcripts = items.sorted { $0.date > $1.date }
            print("📋 Loaded \(transcripts.count) transcripts")
        } catch {
            print("❌ TranscriptManager: error loading transcripts: \(error)")
        }
    }
}
