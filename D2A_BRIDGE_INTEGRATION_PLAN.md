# D2A Bridge Integration Plan for Audio Recording Manager

## 📋 Overview

This document outlines the integration of D2A file decryption support into the Audio Recording Manager Swift app using the [d2aDecrypter Windows service](https://github.com/Fr35ch/d2aDecrypter).

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    macOS (Audio Recording Manager)           │
│                                                              │
│  ┌────────────────┐     ┌──────────────────────────────┐   │
│  │  RecordingStore│     │  D2ABridge (New Module)      │   │
│  │  RecordingsMan.│◄────┤  - VMService Client          │   │
│  └────────────────┘     │  - Password Prompt           │   │
│                         │  - File Converter            │   │
│         ▲               └──────────┬───────────────────┘   │
│         │                          │ HTTP REST              │
│         │ WAV                      │                        │
│         │                          ▼                        │
│  ┌──────────────────┐    ┌──────────────────┐             │
│  │  SD Card Watcher │    │ VMware Shared    │             │
│  │  (New)           │────│ Folder           │             │
│  └──────────────────┘    │ /Volumes/VM.../  │             │
│         │                └──────────────────┘             │
└─────────┼──────────────────────────┼──────────────────────┘
          │                          │
          │ D2A Files                │ HTTP (Port 8080)
          │                          │
┌─────────▼──────────────────────────▼──────────────────────┐
│              VMware Fusion (Windows VM)                    │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  D2ADecrypter Service (C# / .NET 8)                 │  │
│  │  https://github.com/Fr35ch/d2aDecrypter             │  │
│  │  - REST API (Port 8080)                              │  │
│  │  - Olympus SDK COM Integration                       │  │
│  │  - D2A → WAV Conversion                              │  │
│  └─────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

## 📁 New Files to Create

```
audio-recording-manager/
└── Sources/
    └── AudioRecordingManager/
        └── D2A/                          # ← New module
            ├── Models/
            │   ├── D2AFile.swift         # D2A file metadata
            │   ├── DecryptionTask.swift  # Task tracking
            │   └── VMServiceConfig.swift # Service configuration
            ├── Services/
            │   ├── D2ABridgeService.swift # Main bridge coordinator
            │   ├── VMServiceClient.swift  # HTTP REST client
            │   ├── SDCardWatcher.swift    # Disk mount detection
            │   └── D2AConverter.swift     # File conversion handler
            ├── Views/
            │   ├── D2AImportView.swift    # Import UI
            │   ├── PasswordPromptView.swift # Password entry
            │   └── D2AProgressView.swift  # Conversion progress
            └── README.md                  # Module documentation
```

## 🔧 Implementation Steps

### Phase 1: Core Infrastructure (Week 1)

#### 1.1 Create D2A Models

**D2AFile.swift**
```swift
import Foundation

struct D2AFile: Identifiable, Codable {
    let id: UUID
    let name: String
    let path: URL
    let size: Int64
    let isEncrypted: Bool
    let createdAt: Date
    
    init(url: URL) {
        self.id = UUID()
        self.name = url.lastPathComponent
        self.path = url
        self.size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        self.isEncrypted = true // Assume encrypted
        self.createdAt = Date()
    }
}

struct DecryptionTask: Identifiable {
    let id: UUID
    let file: D2AFile
    var status: TaskStatus
    var progress: Double
    var error: String?
    var outputPath: URL?
    
    enum TaskStatus {
        case queued
        case processing
        case completed
        case failed
        case cancelled
    }
}
```

**VMServiceConfig.swift**
```swift
import Foundation

struct VMServiceConfig {
    let serviceURL: URL
    let sharedFolderPath: URL
    let connectionTimeout: TimeInterval
    let maxRetries: Int
    
    static let `default` = VMServiceConfig(
        serviceURL: URL(string: "http://192.168.x.x:8080")!,
        sharedFolderPath: URL(fileURLWithPath: "/Volumes/VMwareShared/SharedFolder"),
        connectionTimeout: 30,
        maxRetries: 3
    )
}
```

#### 1.2 Create REST API Client

**VMServiceClient.swift**
```swift
import Foundation

class VMServiceClient {
    private let config: VMServiceConfig
    private let session: URLSession
    
    init(config: VMServiceConfig = .default) {
        self.config = config
        self.session = URLSession(configuration: .default)
    }
    
    // Health check
    func checkHealth() async throws -> HealthResponse {
        let url = config.serviceURL.appendingPathComponent("api/health")
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw D2ABridgeError.serviceUnavailable
        }
        
        return try JSONDecoder().decode(HealthResponse.swift, from: data)
    }
    
    // Request decryption
    func decrypt(file: D2AFile, password: String) async throws -> DecryptResponse {
        let url = config.serviceURL.appendingPathComponent("api/decrypt")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = DecryptRequest(
            filename: file.name,
            password: password,
            outputFormat: "wav",
            taskId: file.id.uuidString
        )
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw D2ABridgeError.decryptionFailed
        }
        
        return try JSONDecoder().decode(DecryptResponse.self, from: data)
    }
    
    // Check task status
    func checkStatus(taskId: String) async throws -> DecryptResponse {
        let url = config.serviceURL
            .appendingPathComponent("api/status/\(taskId)")
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(DecryptResponse.self, from: data)
    }
}

// Response models
struct HealthResponse: Codable {
    let status: String
    let sdkVersion: String
    let uptime: Int64
    let activeTasks: Int
}

struct DecryptRequest: Codable {
    let filename: String
    let password: String
    let outputFormat: String
    let taskId: String?
}

struct DecryptResponse: Codable {
    let taskId: String
    let status: String
    let outputFile: String?
    let progress: Int
    let error: String?
}

enum D2ABridgeError: LocalizedError {
    case serviceUnavailable
    case decryptionFailed
    case incorrectPassword
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "Windows VM service is not available"
        case .decryptionFailed:
            return "Failed to decrypt D2A file"
        case .incorrectPassword:
            return "Incorrect password"
        case .fileNotFound:
            return "File not found"
        }
    }
}
```

#### 1.3 SD Card Watcher

**SDCardWatcher.swift**
```swift
import Foundation
import DiskArbitration

class SDCardWatcher: ObservableObject {
    @Published var mountedVolumes: [URL] = []
    @Published var d2aFiles: [D2AFile] = []
    
    private var diskSession: DASession?
    
    func startMonitoring() {
        diskSession = DASessionCreate(kCFAllocatorDefault)
        
        guard let session = diskSession else { return }
        
        DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        
        let callback: DADiskAppearedCallback = { disk, context in
            // Handle disk appeared
            guard let watcher = context?.assumingMemoryBound(to: SDCardWatcher.self).pointee else { return }
            
            if let dict = DADiskCopyDescription(disk) as? [String: Any],
               let volumePath = dict[kDADiskDescriptionVolumePathKey as String] as? URL {
                watcher.handleDiskMounted(at: volumePath)
            }
        }
        
        DARegisterDiskAppearedCallback(session, nil, callback, Unmanaged.passUnretained(self).toOpaque())
    }
    
    private func handleDiskMounted(at url: URL) {
        mountedVolumes.append(url)
        scanForD2AFiles(in: url)
    }
    
    private func scanForD2AFiles(in directory: URL) {
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "d2a" {
                let d2aFile = D2AFile(url: fileURL)
                DispatchQueue.main.async {
                    self.d2aFiles.append(d2aFile)
                }
            }
        }
        
        print("📁 Found \(d2aFiles.count) D2A files on \(directory.lastPathComponent)")
    }
}
```

### Phase 2: UI Components (Week 2)

#### 2.1 Password Prompt

**PasswordPromptView.swift**
```swift
import SwiftUI

struct PasswordPromptView: View {
    @Binding var password: String
    @Binding var isPresented: Bool
    let fileName: String
    let onSubmit: (String) -> Void
    
    @State private var showPassword = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Passord kreves")
                .font(.headline)
            
            Text("Filen \"\(fileName)\" er kryptert.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack {
                if showPassword {
                    TextField("Passord", text: $password)
                } else {
                    SecureField("Passord", text: $password)
                }
                
                Button(action: { showPassword.toggle() }) {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Avbryt") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Dekrypter") {
                    onSubmit(password)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.count < 4)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
```

#### 2.2 D2A Import View

**D2AImportView.swift**
```swift
import SwiftUI

struct D2AImportView: View {
    @StateObject private var sdCardWatcher = SDCardWatcher()
    @StateObject private var bridgeService = D2ABridgeService()
    
    @State private var selectedFiles: Set<UUID> = []
    @State private var showPasswordPrompt = false
    @State private var currentFile: D2AFile?
    @State private var password = ""
    
    var body: some View {
        VStack {
            if sdCardWatcher.d2aFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .onAppear {
            sdCardWatcher.startMonitoring()
        }
        .sheet(isPresented: $showPasswordPrompt) {
            if let file = currentFile {
                PasswordPromptView(
                    password: $password,
                    isPresented: $showPasswordPrompt,
                    fileName: file.name
                ) { pwd in
                    Task {
                        await importFile(file, password: pwd)
                    }
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "sdcard")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Sett inn SD-kort")
                .font(.headline)
            
            Text("D2A-filer vil vises her automatisk")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var fileList: some View {
        List(sdCardWatcher.d2aFiles) { file in
            D2AFileRow(
                file: file,
                isSelected: selectedFiles.contains(file.id),
                onImport: {
                    currentFile = file
                    showPasswordPrompt = true
                }
            )
        }
    }
    
    private func importFile(_ file: D2AFile, password: String) async {
        do {
            try await bridgeService.importD2AFile(file, password: password)
            // File imported successfully
            NotificationCenter.default.post(
                name: RecordingStore.didChangeNotification,
                object: nil
            )
        } catch {
            print("❌ Import failed: \(error)")
        }
    }
}

struct D2AFileRow: View {
    let file: D2AFile
    let isSelected: Bool
    let onImport: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundColor(.blue)
            
            VStack(alignment: .leading) {
                Text(file.name)
                    .font(.headline)
                
                Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if file.isEncrypted {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)
            }
            
            Button("Importer") {
                onImport()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}
```

### Phase 3: Bridge Service (Week 2)

**D2ABridgeService.swift**
```swift
import Foundation

@MainActor
class D2ABridgeService: ObservableObject {
    @Published var isVMAvailable = false
    @Published var activeTasks: [DecryptionTask] = []
    
    private let client: VMServiceClient
    private let config: VMServiceConfig
    
    init(config: VMServiceConfig = .default) {
        self.config = config
        self.client = VMServiceClient(config: config)
    }
    
    func checkVMStatus() async {
        do {
            let health = try await client.checkHealth()
            isVMAvailable = health.status == "healthy"
            print("✅ Windows VM service is healthy (SDK: \(health.sdkVersion))")
        } catch {
            isVMAvailable = false
            print("❌ Windows VM service unavailable: \(error)")
        }
    }
    
    func importD2AFile(_ file: D2AFile, password: String) async throws {
        // 1. Copy file to shared folder
        let sharedInputFolder = config.sharedFolderPath
            .appendingPathComponent("input")
        try ensureDirectoryExists(at: sharedInputFolder)
        
        let destinationURL = sharedInputFolder.appendingPathComponent(file.name)
        try FileManager.default.copyItem(at: file.path, to: destinationURL)
        
        // 2. Request decryption via REST API
        let response = try await client.decrypt(file: file, password: password)
        
        // 3. Create task and monitor progress
        var task = DecryptionTask(
            id: UUID(uuidString: response.taskId) ?? UUID(),
            file: file,
            status: .processing,
            progress: 0,
            error: nil,
            outputPath: nil
        )
        activeTasks.append(task)
        
        // 4. Poll for completion
        try await monitorTask(&task)
        
        // 5. Import WAV to RecordingStore
        if task.status == .completed, let outputPath = task.outputPath {
            try await importToRecordingStore(wavURL: outputPath, originalName: file.name)
        }
    }
    
    private func monitorTask(_ task: inout DecryptionTask) async throws {
        while task.status == .processing {
            let response = try await client.checkStatus(taskId: task.id.uuidString)
            
            task.progress = Double(response.progress) / 100.0
            
            if response.status == "Completed" {
                task.status = .completed
                
                // Get output file from shared folder
                let sharedOutputFolder = config.sharedFolderPath
                    .appendingPathComponent("output")
                task.outputPath = sharedOutputFolder
                    .appendingPathComponent(response.outputFile ?? "")
                
            } else if response.status == "Failed" {
                task.status = .failed
                task.error = response.error
                throw D2ABridgeError.decryptionFailed
            }
            
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }
    
    private func importToRecordingStore(wavURL: URL, originalName: String) async throws {
        // Import WAV file into RecordingStore
        let recordingID = UUID()
        let meta = RecordingMeta.create(id: recordingID)
        
        // Copy WAV to recordings folder
        let recordingFolder = StorageLayout.recordingFolder(id: recordingID)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        
        let audioFilename = "audio.wav"
        let destinationURL = recordingFolder.appendingPathComponent(audioFilename)
        try FileManager.default.copyItem(at: wavURL, to: destinationURL)
        
        // Update metadata
        var updatedMeta = meta
        updatedMeta.displayName = originalName.replacingOccurrences(of: ".d2a", with: "")
        updatedMeta.audio.status = .done
        updatedMeta.audio.filename = audioFilename
        
        // Calculate duration and size
        if let audioFile = try? AVAudioFile(forReading: destinationURL) {
            updatedMeta.durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        }
        updatedMeta.audio.sizeBytes = try? FileManager.default
            .attributesOfItem(atPath: destinationURL.path)[.size] as? Int64
        
        try RecordingStore.shared.save(updatedMeta)
        
        print("✅ Imported D2A file as recording: \(updatedMeta.displayName)")
    }
    
    private func ensureDirectoryExists(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }
}
```

## 🔗 Integration with Existing App

### Update main.swift

Add D2A import tab to the main navigation:

```swift
// In MainView or similar
TabView {
    // ... existing tabs ...
    
    D2AImportView()
        .tabItem {
            Label("D2A Import", systemImage: "sdcard")
        }
}
```

### Update RecordingStore

Add method to import external WAV files:

```swift
extension RecordingStore {
    func importExternalAudio(from url: URL, displayName: String) throws -> UUID {
        let id = UUID()
        let meta = RecordingMeta.create(id: id)
        
        // ... (implementation from D2ABridgeService.importToRecordingStore)
        
        return id
    }
}
```

## 📝 Configuration

### VMware Setup

1. **Enable Shared Folders** in VMware Fusion
2. **Create shared folder** named "SharedFolder"
3. **Map to Windows** as Z:\ drive
4. **Start D2A Decryption Service** on VM boot

### Config File

Create `~/Library/Application Support/AudioRecordingManager/d2a-config.json`:

```json
{
  "vmServiceURL": "http://192.168.x.x:8080",
  "sharedFolderPath": "/Volumes/VMwareShared/SharedFolder",
  "autoImportEnabled": true,
  "defaultPassword": null
}
```

## ✅ Testing Checklist

- [ ] VM service health check works
- [ ] SD card detection triggers file list
- [ ] Password prompt appears for encrypted files
- [ ] Decryption request succeeds
- [ ] Progress updates in real-time
- [ ] WAV file imported to RecordingStore
- [ ] File appears in recordings list
- [ ] Handles incorrect password gracefully
- [ ] Handles corrupted D2A files
- [ ] Cleans up shared folder after import

## 📚 Documentation to Create

1. **User Guide**: How to set up VMware and Windows service
2. **Developer Guide**: How the bridge works
3. **Troubleshooting**: Common issues and solutions

## 🚀 Next Session

In the next session, I'll:
1. Create all the Swift files listed above
2. Integrate with your existing RecordingStore
3. Add D2A import tab to your UI
4. Test the complete workflow
5. Create comprehensive documentation

---

**Ready to implement?** Share this repo URL with me next time: `https://github.com/Fr35ch/audio-recording-manager`
