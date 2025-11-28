import AVFAudio
import AVFoundation
import CoreWLAN
import DiskArbitration
import Foundation
import IOBluetooth
import SwiftUI

// MARK: - Configuration
/// Set to true for demo/testing, false for production
let DEMO_MODE = true  // TODO: Set to false when deploying to production

// MARK: - NAV Aksel Design System
/// NAV Design Tokens - Colors, spacing, and typography based on Aksel design system
struct NAVColors {
    // Primary Colors
    static let blue = Color(hex: "0067C5")  // Primary action color
    static let blueHover = Color(hex: "0056B4")  // Blue hover state
    static let navRed = Color(hex: "C30000")  // NAV brand red / Danger
    static let green = Color(hex: "06893A")  // Success
    static let orange = Color(hex: "FF9100")  // Warning

    // Backgrounds
    static let bgDefault = Color.white
    static let bgSubtle = Color(hex: "ECEEF0")  // Gray-100

    // Text
    static let textDefault = Color(hex: "23262A")  // Gray-900
    static let textSubtle = Color(hex: "010B18").opacity(0.68)  // GrayAlpha-700

    // Surface
    static let surfaceAction = blue
    static let surfaceActionHover = blueHover
}

struct NAVSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

struct NAVRadius {
    static let small: CGFloat = 2
    static let medium: CGFloat = 4
    static let large: CGFloat = 8
    static let xlarge: CGFloat = 12
    static let full: CGFloat = 9999
}

// Helper for hex colors
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - NAV Design System Note
// The Aksel design system is built for React/web and cannot be directly used in native Swift.
// Instead, we use:
// - NAV color palette (defined in NAVColors)
// - NAV spacing scale (defined in NAVSpacing)
// - NAV border radius (defined in NAVRadius)
// - SF Symbols (Apple's native icons) styled with NAV colors

// MARK: - App Entry Point
@main
struct VirginProjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - App Delegate for Launch Configuration
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if DEMO_MODE {
            print("⚠️  DEMO MODE ACTIVE - Network will NOT be disabled on launch")
            print("⚠️  Set DEMO_MODE = false for production deployment")
        } else {
            // Disable network and Bluetooth on launch (production mode)
            NetworkManager.shared.disableAllConnections()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep app running even if window closed
    }
}

// MARK: - Network Manager (Security Critical)
class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    @Published var wifiEnabled: Bool = true
    @Published var bluetoothEnabled: Bool = true
    @Published var isNetworkOverrideActive: Bool = false

    private init() {
        updateStatus()
    }

    /// Disable all network connections (WiFi, Bluetooth, AirDrop)
    func disableAllConnections() {
        disableWiFi()
        disableBluetooth()
        // AirDrop is disabled when WiFi and Bluetooth are off
        updateStatus()
    }

    /// Enable all network connections
    func enableAllConnections() {
        enableWiFi()
        enableBluetooth()
        isNetworkOverrideActive = true
        updateStatus()
    }

    /// Disable WiFi using networksetup command
    private func disableWiFi() {
        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments = ["-setairportpower", "en0", "off"]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Failed to disable WiFi: \(error)")
        }
    }

    /// Enable WiFi using networksetup command
    func enableWiFi() {
        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments = ["-setairportpower", "en0", "on"]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Failed to enable WiFi: \(error)")
        }
    }

    /// Disable Bluetooth using system commands
    private func disableBluetooth() {
        // Use blueutil if available, otherwise use AppleScript
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = [
            "-c",
            "blueutil -p 0 2>/dev/null || osascript -e 'tell application \"System Settings\" to quit' -e 'do shell script \"sudo defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int 0 && sudo killall -HUP blued\" with administrator privileges' 2>/dev/null",
        ]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Failed to disable Bluetooth: \(error)")
        }
    }

    /// Enable Bluetooth
    private func enableBluetooth() {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = [
            "-c",
            "blueutil -p 1 2>/dev/null || osascript -e 'tell application \"System Settings\" to quit' -e 'do shell script \"sudo defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int 1 && sudo killall -HUP blued\" with administrator privileges' 2>/dev/null",
        ]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Failed to enable Bluetooth: \(error)")
        }
    }

    /// Update current network status
    func updateStatus() {
        // Check WiFi status
        if let interface = CWWiFiClient.shared().interface() {
            wifiEnabled = interface.powerOn()
        }

        // Check Bluetooth status
        let btHost = IOBluetoothHostController.default()
        bluetoothEnabled = btHost?.powerState == kBluetoothHCIPowerStateON
    }
}

// MARK: - File Manager
class AudioFileManager: ObservableObject {
    static let shared = AudioFileManager()

    let audioFolderPath: String

    private init() {
        // Create lydfiler folder on Desktop
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)
            .first!
        audioFolderPath = desktopPath.appendingPathComponent("lydfiler").path

        createAudioFolder()
    }

    /// Create the lydfiler folder if it doesn't exist
    func createAudioFolder() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: audioFolderPath) {
            do {
                try fileManager.createDirectory(
                    atPath: audioFolderPath, withIntermediateDirectories: true)
                print("Created lydfiler folder at: \(audioFolderPath)")
            } catch {
                print("Failed to create lydfiler folder: \(error)")
            }
        }
    }

    /// Generate timestamped filename: lydfil_YYYYMMDD_HHMMSS
    func generateFilename(extension ext: String = "m4a") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return "lydfil_\(timestamp).\(ext)"
    }

    /// Get full path for a new audio file
    func getNewFilePath(extension ext: String = "m4a") -> String {
        let filename = generateFilename(extension: ext)
        return (audioFolderPath as NSString).appendingPathComponent(filename)
    }
}

// MARK: - Audio Recorder
class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = AudioRecorder()

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var lastSavedFile: String?
    @Published var showSaveConfirmation = false
    @Published var frequencyBands: [Float] = Array(repeating: 0, count: 32)
    @Published var isMonitoring = false

    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var levelTimer: Timer?
    private var currentRecordingURL: URL?
    private var monitorRecorder: AVAudioRecorder?

    private override init() {
        super.init()
        print("✅ Audio recorder initialized")
    }

    // MARK: - Audio Monitoring (for visualization before recording)

    func startMonitoring() {
        guard !isMonitoring else { return }

        // Create a temporary URL for monitoring (won't save)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "monitor.m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            monitorRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
            monitorRecorder?.isMeteringEnabled = true
            monitorRecorder?.prepareToRecord()
            monitorRecorder?.record()

            isMonitoring = true
            startLevelMonitoring()
            print("🎤 Started audio monitoring")
        } catch {
            print("❌ Error starting monitoring: \(error)")
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        monitorRecorder?.stop()
        monitorRecorder = nil
        isMonitoring = false
        stopLevelMonitoring()

        // Clear visualization
        frequencyBands = Array(repeating: 0, count: 32)
        audioLevel = 0

        print("🛑 Stopped audio monitoring")
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Use monitor recorder if not recording, otherwise use main recorder
            let recorder = self.isRecording ? self.audioRecorder : self.monitorRecorder
            guard let recorder = recorder else { return }

            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            let peakPower = recorder.peakPower(forChannel: 0)

            // Convert dB to 0-1 range with balanced sensitivity
            let minDB: Float = -50.0
            let maxDB: Float = -5.0
            let clampedAverage = max(minDB, min(maxDB, averagePower))
            let normalizedLevel = (clampedAverage - minDB) / (maxDB - minDB)
            self.audioLevel = normalizedLevel

            // Generate frequency band visualization
            for i in 0..<32 {
                let bandFrequency = Float(i) / 32.0
                let clampedPeak = max(minDB, min(maxDB, peakPower))
                let powerVariance = (clampedPeak - minDB) / (maxDB - minDB)
                let randomVariation = Float.random(in: 0.85...1.15)
                let frequencyWeight = 1.0 - (bandFrequency * 0.6)
                let amplification: Float = 1.8
                let bandLevel =
                    normalizedLevel * frequencyWeight * randomVariation * powerVariance
                    * amplification

                let smoothing: Float = 0.55
                self.frequencyBands[i] =
                    self.frequencyBands[i] * smoothing + bandLevel * (1 - smoothing)
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - Recording Control

    func startRecording() {
        // Stop monitoring when actual recording starts
        if isMonitoring {
            stopMonitoring()
        }
        // Generate file path in lydfiler folder
        let filePath = AudioFileManager.shared.getNewFilePath(extension: "m4a")
        currentRecordingURL = URL(fileURLWithPath: filePath)

        guard let url = currentRecordingURL else {
            print("❌ Failed to create recording URL")
            return
        }

        // Configure recording settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()

            if audioRecorder?.record() == true {
                isRecording = true
                isPaused = false
                recordingDuration = 0

                // Start timers (level monitoring continues)
                startRecordingTimer()
                if !isMonitoring {
                    startLevelMonitoring()
                }

                print("✅ Started recording to: \(url.lastPathComponent)")
            } else {
                print("❌ Failed to start recording")
            }
        } catch {
            print("❌ Error creating audio recorder: \(error)")
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        audioRecorder?.pause()
        isPaused = true
        stopRecordingTimer()

        print("⏸️ Recording paused")
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        audioRecorder?.record()
        isPaused = false
        startRecordingTimer()

        print("▶️ Recording resumed")
    }

    func stopRecording() {
        guard isRecording else { return }

        audioRecorder?.stop()
        isRecording = false
        isPaused = false
        stopRecordingTimer()

        if let url = currentRecordingURL {
            lastSavedFile = url.lastPathComponent
            showSaveConfirmation = true
            print("✅ Recording saved: \(url.lastPathComponent)")

            // Hide confirmation and reset timer after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.showSaveConfirmation = false
                self.recordingDuration = 0
            }
        }

        audioRecorder = nil
        currentRecordingURL = nil

        // Restart monitoring to keep visualization active
        startMonitoring()
    }

    func deleteCurrentRecording() {
        if isRecording {
            stopRecording()
        }

        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            print("🗑️ Recording deleted")
        }

        recordingDuration = 0
        audioLevel = 0
        currentRecordingURL = nil
    }

    // MARK: - Recording Timer (duration only)

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder else { return }
            self.recordingDuration = recorder.currentTime
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag {
            print("✅ Recording finished successfully")
        } else {
            print("❌ Recording failed")
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("❌ Recording error: \(error)")
        }
    }
}

// MARK: - Recording Item Model
struct RecordingItem: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let path: String
    let date: Date
    let size: Int64

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// MARK: - Audio Player
class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()

    @Published var isPlaying = false
    @Published var currentPlayingFile: String?
    @Published var playbackProgress: Double = 0
    @Published var duration: TimeInterval = 0

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    private override init() {
        super.init()
    }

    func play(url: URL) {
        // Stop current playback if any
        stop()

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            if let player = audioPlayer {
                duration = player.duration
                player.play()
                isPlaying = true
                currentPlayingFile = url.lastPathComponent
                startProgressTimer()
                print("▶️ Playing: \(url.lastPathComponent)")
            }
        } catch {
            print("❌ Error playing audio: \(error)")
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentPlayingFile = nil
        playbackProgress = 0
        stopProgressTimer()
    }

    func togglePlayPause() {
        guard let player = audioPlayer else { return }

        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopProgressTimer()
        } else {
            // Restart from the beginning
            player.currentTime = 0
            player.play()
            isPlaying = true
            playbackProgress = 0
            startProgressTimer()
        }
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.playbackProgress = player.currentTime / player.duration
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentPlayingFile = nil
        playbackProgress = 0
        stopProgressTimer()
    }
}

// MARK: - Recordings Manager
class RecordingsManager: ObservableObject {
    static let shared = RecordingsManager()

    @Published var recordings: [RecordingItem] = []

    private init() {
        loadRecordings()
    }

    func loadRecordings() {
        let audioFolder = AudioFileManager.shared.audioFolderPath
        let fileManager = FileManager.default

        do {
            let files = try fileManager.contentsOfDirectory(atPath: audioFolder)
            var items: [RecordingItem] = []

            for file in files {
                let filePath = (audioFolder as NSString).appendingPathComponent(file)
                let fileURL = URL(fileURLWithPath: filePath)

                guard fileURL.pathExtension.lowercased() == "m4a" else { continue }

                let attributes = try fileManager.attributesOfItem(atPath: filePath)
                if let fileSize = attributes[.size] as? Int64,
                    let modDate = attributes[.modificationDate] as? Date
                {
                    items.append(
                        RecordingItem(
                            filename: file,
                            path: filePath,
                            date: modDate,
                            size: fileSize
                        ))
                }
            }

            // Sort by date, newest first
            recordings = items.sorted { $0.date > $1.date }
            print("📋 Loaded \(recordings.count) recordings")
        } catch {
            print("❌ Error loading recordings: \(error)")
        }
    }

    func deleteRecording(_ item: RecordingItem) {
        do {
            try FileManager.default.removeItem(atPath: item.path)
            loadRecordings()
            print("🗑️ Deleted: \(item.filename)")
        } catch {
            print("❌ Error deleting recording: \(error)")
        }
    }
}

// MARK: - NAV Button Styles

struct NAVPrimaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, NAVSpacing.xl)
            .padding(.vertical, NAVSpacing.lg)
            .background(
                configuration.isPressed
                    ? NAVColors.blueHover.opacity(0.9)
                    : (isHovering ? NAVColors.blueHover : NAVColors.blue)
            )
            .foregroundColor(.white)
            .cornerRadius(NAVRadius.large)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }
    }
}

struct NAVSecondaryButtonStyle: ButtonStyle {
    let backgroundColor: Color
    let hoverColor: Color

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, NAVSpacing.xl)
            .padding(.vertical, NAVSpacing.lg)
            .background(
                configuration.isPressed
                    ? hoverColor.opacity(0.9) : (isHovering ? hoverColor : backgroundColor)
            )
            .foregroundColor(.white)
            .cornerRadius(NAVRadius.large)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }
    }
}

// Hover button style with light gray background on hover
struct HoverButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isHovering ? Color.secondary.opacity(0.1) : Color.clear)
            .cornerRadius(4)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }
    }
}

// MARK: - Cursor Modifier
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.background(
            GeometryReader { geometry in
                CursorHostingView(cursor: cursor, frame: geometry.frame(in: .local))
            }
        )
    }
}

struct CursorHostingView: NSViewRepresentable {
    let cursor: NSCursor
    let frame: CGRect

    func makeNSView(context: Context) -> CursorTrackingView {
        let view = CursorTrackingView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorTrackingView, context: Context) {
        nsView.cursor = cursor
    }
}

class CursorTrackingView: NSView {
    var cursor: NSCursor = .arrow
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate,
        ]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
}

// MARK: - Audio File Info Model
struct AudioFileInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let modificationDate: Date
    let fileExtension: String

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }
}

// MARK: - SD Card Manager
class SDCardManager: ObservableObject {
    static let shared = SDCardManager()

    @Published var isSDCardInserted = false
    @Published var sdCardPath: String?
    @Published var sdCardVolumeName: String?
    @Published var audioFiles: [AudioFileInfo] = []
    @Published var isScanning = false

    private var session: DASession?
    private var pollingTimer: Timer?

    private init() {
        setupDiskArbitration()
        startPolling()
    }

    deinit {
        pollingTimer?.invalidate()
        if let session = session {
            DASessionUnscheduleFromRunLoop(
                session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    // MARK: - Polling Mechanism (Fallback)
    private func startPolling() {
        // Poll every 2 seconds to check for SD cards as a fallback
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkForSDCard()
        }
    }

    private func checkForSDCard() {
        let fileManager = FileManager.default
        guard let volumes = try? fileManager.contentsOfDirectory(atPath: "/Volumes") else { return }

        // List of system/internal volumes to ignore
        let systemVolumes = [
            "Macintosh HD", ".", "..", "Preboot", "Recovery", "VM", "Update", "Data",
        ]

        // Check if we have a removable volume that's not currently detected
        for volume in volumes {
            let volumePath = "/Volumes/\(volume)"

            // Skip system volumes and hidden volumes
            if systemVolumes.contains(volume) || volume.hasPrefix(".") {
                continue
            }

            // Skip volumes that start with "Macintosh" (various forms of system volumes)
            if volume.hasPrefix("Macintosh") {
                continue
            }

            // Check if this volume is actually removable media
            // We do this by checking volume characteristics via URL
            let volumeURL = URL(fileURLWithPath: volumePath)
            do {
                let resourceValues = try volumeURL.resourceValues(forKeys: [
                    .volumeIsRemovableKey,
                    .volumeIsEjectableKey,
                    .volumeIsLocalKey,
                    .volumeIsInternalKey,
                    .volumeIsReadOnlyKey,
                ])

                // Exclude disk images and network volumes - accept physical drives
                // A valid SD card must be:
                // 1. Removable OR ejectable (physical media can be removed)
                // 2. Local (not network)
                // 3. Writable (not read-only like PKG/DMG installers)
                // Note: Don't check isInternal - built-in SD card readers are marked as internal
                if let isRemovable = resourceValues.volumeIsRemovable,
                    let isEjectable = resourceValues.volumeIsEjectable,
                    let isLocal = resourceValues.volumeIsLocal,
                    let isReadOnly = resourceValues.volumeIsReadOnly,
                    isRemovable || isEjectable,
                    isLocal
                {

                    // Skip read-only volumes (installers, disk images)
                    if isReadOnly {
                        print("📊 Skipping read-only volume (likely installer): \(volume)")
                        continue
                    }

                    // Additional check: skip disk images by checking if volume name suggests it's an installer
                    let installerKeywords = [
                        "installer", "dmg", "player", "setup", "install", "wacom", "driver", "pkg",
                    ]
                    let volumeLower = volume.lowercased()
                    if installerKeywords.contains(where: { volumeLower.contains($0) }) {
                        print("📊 Skipping potential disk image: \(volume)")
                        continue
                    }

                    // Check if path is from a disk image using diskutil
                    // Disk images typically mount without partition numbers (disk6, disk8)
                    // Real SD cards have partitions (disk2s1, disk4s2)
                    let diskutilTask = Process()
                    diskutilTask.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                    diskutilTask.arguments = ["info", volumePath]
                    let pipe = Pipe()
                    diskutilTask.standardOutput = pipe

                    try? diskutilTask.run()
                    diskutilTask.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8) {
                        if output.contains("Disk Image: Yes")
                            || output.contains("Protocol: Disk Image")
                        {
                            print("📊 Skipping disk image detected by diskutil: \(volume)")
                            continue
                        }
                    }

                    // If we find a valid removable volume but our state says no SD card, update it
                    if !isSDCardInserted {
                        DispatchQueue.main.async {
                            self.sdCardPath = volumePath
                            self.sdCardVolumeName = volume
                            self.isSDCardInserted = true
                            print("📊 Polling detected removable media: \(volume) at \(volumePath)")
                            self.scanForAudioFiles()
                            self.objectWillChange.send()  // Force UI update
                        }
                        return
                    }
                }
            } catch {
                // If we can't get resource values, skip this volume
                continue
            }
        }

        // Check if SD card was removed
        if isSDCardInserted, let path = sdCardPath {
            if !fileManager.fileExists(atPath: path) {
                DispatchQueue.main.async {
                    self.isSDCardInserted = false
                    self.sdCardPath = nil
                    self.sdCardVolumeName = nil
                    self.audioFiles = []
                    print("📊 Polling detected SD card removal")
                    self.objectWillChange.send()  // Force UI update
                }
            }
        }
    }

    // MARK: - Disk Arbitration Setup
    private func setupDiskArbitration() {
        print("🔧 Setting up DiskArbitration...")

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            print("❌ Failed to create DiskArbitration session")
            return
        }

        self.session = session
        print("✅ DiskArbitration session created")

        // Schedule on MAIN run loop (not current, which might be different in SwiftUI)
        DASessionScheduleWithRunLoop(
            session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        print("✅ Session scheduled on main run loop")

        let appearedCallback: DADiskAppearedCallback = { disk, context in
            print("🚨 DISK APPEARED CALLBACK FIRED!")
            guard let context = context else {
                print("❌ No context in callback")
                return
            }
            let manager = Unmanaged<SDCardManager>.fromOpaque(context).takeUnretainedValue()
            manager.diskAppeared(disk: disk)
        }

        let disappearedCallback: DADiskDisappearedCallback = { disk, context in
            print("🚨 DISK DISAPPEARED CALLBACK FIRED!")
            guard let context = context else { return }
            let manager = Unmanaged<SDCardManager>.fromOpaque(context).takeUnretainedValue()
            manager.diskDisappeared(disk: disk)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, appearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, disappearedCallback, context)
        print("✅ Callbacks registered")

        print("✅ SD Card monitoring started - waiting for disk events...")
    }

    // MARK: - Disk Events
    private func diskAppeared(disk: DADisk) {
        guard let diskDescription = DADiskCopyDescription(disk) as? [String: Any] else { return }

        // Get volume path - can be either a URL or a String
        var volumePath: String? = nil
        if let pathURL = diskDescription[kDADiskDescriptionVolumePathKey as String] as? URL {
            volumePath = pathURL.path
        } else if let pathString = diskDescription[kDADiskDescriptionVolumePathKey as String]
            as? String
        {
            volumePath = pathString
        }

        print("\n🔍 ======== DISK APPEARED ========")
        print(
            "📀 Volume Name: \(diskDescription[kDADiskDescriptionVolumeNameKey as String] as? String ?? "Unknown")"
        )
        print("📂 Volume Path: \(volumePath ?? "None")")
        print(
            "🔌 Removable: \(diskDescription[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false)"
        )
        print("================================\n")

        if isValidSDCard(description: diskDescription) {
            // Wait for volume to be mounted, then process
            self.waitForVolumeMount(disk: disk, attempts: 0)
        }
    }

    private func waitForVolumeMount(disk: DADisk, attempts: Int) {
        guard attempts < 10 else {
            print("⚠️ Failed to get volume path after 10 attempts")
            return
        }

        // IMPORTANT: Re-query the disk description on each attempt!
        // The disk description changes as the volume gets mounted
        guard let diskDescription = DADiskCopyDescription(disk) as? [String: Any] else {
            print("⚠️ Could not get disk description")
            return
        }

        // Get volume path - can be either a URL or a String
        var volumePath: String? = nil
        if let pathURL = diskDescription[kDADiskDescriptionVolumePathKey as String] as? URL {
            volumePath = pathURL.path
        } else if let pathString = diskDescription[kDADiskDescriptionVolumePathKey as String]
            as? String
        {
            volumePath = pathString
        }

        if let path = volumePath {
            // Success! We have the path
            DispatchQueue.main.async {
                self.sdCardVolumeName =
                    diskDescription[kDADiskDescriptionVolumeNameKey as String] as? String
                self.sdCardPath = path
                self.isSDCardInserted = true

                print("✅ ======== SD CARD DETECTED ========")
                print("📍 Path: \(path)")
                print("📛 Name: \(self.sdCardVolumeName ?? "Unknown")")
                print("🔍 Scanning for audio files...")
                print("====================================\n")

                self.scanForAudioFiles()
                self.launchDSSPlayer()
            }
        } else {
            // No path yet, retry after a delay
            print("⏳ Waiting for volume to mount (attempt \(attempts + 1)/10)...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.waitForVolumeMount(disk: disk, attempts: attempts + 1)
            }
        }
    }

    private func diskDisappeared(disk: DADisk) {
        guard let diskDescription = DADiskCopyDescription(disk) as? [String: Any] else { return }

        let volumeName =
            diskDescription[kDADiskDescriptionVolumeNameKey as String] as? String ?? "Unknown"

        if isValidSDCard(description: diskDescription) {
            DispatchQueue.main.async {
                print("\n⏏️ ======== SD CARD REMOVED ========")
                print("📛 Name: \(volumeName)")
                print("====================================\n")

                self.isSDCardInserted = false
                self.sdCardPath = nil
                self.sdCardVolumeName = nil
                self.audioFiles = []
            }
        }
    }

    // MARK: - SD Card Validation
    private func isValidSDCard(description: [String: Any]) -> Bool {
        // Check if media is removable (USB drives, SD cards, etc.)
        guard let removable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool,
            removable
        else {
            print("🔍 Disk is not removable, skipping")
            return false
        }

        // Exclude disk images by checking the device protocol
        if let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String]
            as? String
        {
            if deviceProtocol == "Disk Image" || deviceProtocol == "Virtual Interface" {
                print("🔍 Disk is a disk image or virtual device, skipping")
                return false
            }
        }

        // Check BSD name - disk images are typically disk2+, while real SD cards are usually disk2s2 or similar
        // Disk images: disk6, disk8, etc.
        // Real media: disk2s1, disk4s2, etc. (with partition numbers)
        if let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String {
            // Pattern: "diskN" without partition number is usually a disk image
            // Real media has partition numbers: "diskNsM"
            let diskImagePattern = "^disk[0-9]+$"
            if bsdName.range(of: diskImagePattern, options: .regularExpression) != nil {
                print("🔍 BSD name pattern suggests disk image (\(bsdName)), skipping")
                return false
            }
        }

        // Check if volume is read-only (many PKG/DMG installers are read-only)
        if let volumeWritable = description[kDADiskDescriptionMediaWritableKey as String] as? Bool {
            if !volumeWritable {
                print("🔍 Volume is read-only (likely installer/disk image), skipping")
                return false
            }
        }

        // Check volume name to skip installers
        if let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String {
            let installerKeywords = [
                "installer", "dmg", "player", "setup", "install", "wacom", "driver", "pkg",
            ]
            let volumeLower = volumeName.lowercased()
            if installerKeywords.contains(where: { volumeLower.contains($0) }) {
                print("🔍 Volume name suggests disk image (\(volumeName)), skipping")
                return false
            }
        }

        // Accept physical removable media only
        print("✅ Valid removable media detected")
        return true
    }

    // MARK: - Audio File Scanning
    func scanForAudioFiles() {
        guard let sdPath = sdCardPath else {
            audioFiles = []
            return
        }

        isScanning = true
        var foundFiles: [AudioFileInfo] = []
        let fileManager = FileManager.default
        let supportedExtensions = ["m4a", "mp3", "wav", "aiff", "aif", "dss", "ds2", "mp4"]

        if let enumerator = fileManager.enumerator(atPath: sdPath) {
            for case let file as String in enumerator {
                let filePath = (sdPath as NSString).appendingPathComponent(file)
                let fileURL = URL(fileURLWithPath: filePath)
                let ext = fileURL.pathExtension.lowercased()

                if supportedExtensions.contains(ext) {
                    do {
                        let attributes = try fileManager.attributesOfItem(atPath: filePath)
                        if let fileSize = attributes[.size] as? Int64,
                            let modificationDate = attributes[.modificationDate] as? Date
                        {

                            let fileInfo = AudioFileInfo(
                                name: fileURL.lastPathComponent,
                                path: filePath,
                                size: fileSize,
                                modificationDate: modificationDate,
                                fileExtension: ext
                            )
                            foundFiles.append(fileInfo)
                        }
                    } catch {
                        print("⚠️ Error getting file attributes: \(error)")
                    }
                }
            }
        }

        foundFiles.sort { $0.modificationDate > $1.modificationDate }

        DispatchQueue.main.async {
            self.audioFiles = foundFiles
            self.isScanning = false
            print("✅ Found \(foundFiles.count) audio files")
        }
    }

    // MARK: - DSS Player Launch
    func launchDSSPlayer() {
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.olympus.dssplayer")
        {
            openDSSPlayerApp(at: appURL)
            return
        }

        let appPaths = [
            "/Applications/DSS Player.app",
            "/Applications/Olympus DSS Player.app",
            "/Applications/DSSPlayer.app",
            "/Applications/DSS Player Plus.app",
        ]

        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                let appURL = URL(fileURLWithPath: path)
                openDSSPlayerApp(at: appURL)
                return
            }
        }

        print("⚠️ DSS Player app not found")
    }

    private func openDSSPlayerApp(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let sdPath = sdCardPath {
            configuration.arguments = [sdPath]
        }

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error = error {
                print("❌ Error opening DSS Player: \(error.localizedDescription)")
            } else {
                print("✅ DSS Player opened successfully")
            }
        }
    }

    // MARK: - Eject SD Card
    func ejectSDCard() {
        guard let path = sdCardPath else {
            print("⚠️ No SD card path to eject")
            return
        }

        print("⏏️ Attempting to eject SD card at: \(path)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["eject", path]

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                print("✅ SD card ejected successfully")
                // State will be updated by diskDisappeared callback or polling
            } else {
                print("❌ Failed to eject SD card (status: \(task.terminationStatus))")
            }
        } catch {
            print("❌ Error ejecting SD card: \(error.localizedDescription)")
        }
    }
}

// MARK: - Record Button with NAV Styling
struct RecordButton: View {
    let isRecording: Bool
    let isVerified: Bool
    let action: () -> Void
    @State private var isHovering = false
    @State private var showAudioSourceMenu = false

    var body: some View {
        HStack(spacing: 12) {
            // Main Record/Stop Button
            Button(action: action) {
                if isRecording {
                    // Stop button - NAV styled
                    VStack(spacing: NAVSpacing.sm) {
                        Rectangle()
                            .fill(NAVColors.navRed)
                            .frame(width: 56, height: 56)
                            .cornerRadius(NAVRadius.small)
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NAVColors.navRed)
                            .textCase(.uppercase)
                            .tracking(1)
                    }
                } else if isVerified {
                    // Start Recording button - NAV styled (enabled)
                    Text("Start Recording")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .tracking(0.5)
                        .padding(.horizontal, NAVSpacing.xxl + NAVSpacing.sm)
                        .padding(.vertical, NAVSpacing.lg + 2)
                        .background(isHovering ? NAVColors.navRed.opacity(0.85) : NAVColors.navRed)
                        .cornerRadius(NAVRadius.large)
                        .animation(.easeInOut(duration: 0.15), value: isHovering)
                } else {
                    // Verifying state - grey/disabled
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .colorScheme(.dark)
                        Text("Verifying Microphone")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .tracking(0.5)
                    }
                    .padding(.horizontal, NAVSpacing.xxl + NAVSpacing.sm)
                    .padding(.vertical, NAVSpacing.lg + 2)
                    .background(Color.gray.opacity(0.5))
                    .cornerRadius(NAVRadius.large)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isVerified && !isRecording)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if isVerified || isRecording {
                        isHovering = true
                        DispatchQueue.main.async { NSCursor.pointingHand.set() }
                    }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }

            // Audio Source Settings Button (only show when not recording)
            if !isRecording {
                Button(action: {
                    showAudioSourceMenu.toggle()
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .light))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(NAVRadius.medium)
                }
                .buttonStyle(.plain)
                .help("Audio Input Settings")
                .popover(isPresented: $showAudioSourceMenu, arrowEdge: .bottom) {
                    AudioSourceSelector()
                }
            }
        }
    }
}

// MARK: - Audio Source Selector
struct AudioSourceSelector: View {
    @State private var audioDevices: [String] = []
    @State private var selectedDevice: String = "Default"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio Input Source")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Divider()

            // List available audio devices
            VStack(alignment: .leading, spacing: 0) {
                ForEach(
                    audioDevices.isEmpty ? ["Default", "Built-in Microphone"] : audioDevices,
                    id: \.self
                ) { device in
                    Button(action: {
                        selectedDevice = device
                        // TODO: Set audio input device
                    }) {
                        HStack {
                            Text(device)
                                .font(.system(size: 13))
                            Spacer()
                            if selectedDevice == device {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(selectedDevice == device ? Color.blue.opacity(0.1) : Color.clear)
                }
            }

            Divider()

            Text("Change audio input device")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: 250)
        .onAppear {
            loadAudioDevices()
        }
    }

    func loadAudioDevices() {
        // TODO: Get actual audio devices from AVAudioSession/CoreAudio
        audioDevices = ["Default", "Built-in Microphone", "External Microphone"]
    }
}

// MARK: - Folder Item Model
struct FolderItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var isExpanded: Bool = true
    var subfolders: [FolderItem] = []
    var recordings: [RecordingItem] = []
}

// MARK: - Folder Manager
class FolderManager: ObservableObject {
    @Published var folderStructure: [FolderItem] = []
    private let baseURL: URL

    init(basePath: String) {
        self.baseURL = URL(fileURLWithPath: basePath)
        loadFolderStructure()
    }

    func loadFolderStructure() {
        let fileManager = FileManager.default

        // Get all items in lydfiler folder
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: baseURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else {
            return
        }

        var folders: [FolderItem] = []
        var rootRecordings: [RecordingItem] = []

        for item in items {
            let isDirectory =
                (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDirectory {
                let recordings = loadRecordingsInFolder(item)
                let folder = FolderItem(
                    name: item.lastPathComponent,
                    path: item.path,
                    recordings: recordings
                )
                folders.append(folder)
            } else if item.pathExtension == "m4a" || item.pathExtension == "mp3"
                || item.pathExtension == "wav"
            {
                if let recording = createRecordingItem(from: item) {
                    rootRecordings.append(recording)
                }
            }
        }

        // Create root level structure
        folderStructure = folders

        // If there are root-level recordings, add them to the structure
        if !rootRecordings.isEmpty {
            // We'll handle root recordings separately in the UI
        }
    }

    func loadRecordingsInFolder(_ folderURL: URL) -> [RecordingItem] {
        let fileManager = FileManager.default
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            return []
        }

        return items.compactMap { item in
            if item.pathExtension == "m4a" || item.pathExtension == "mp3"
                || item.pathExtension == "wav"
            {
                return createRecordingItem(from: item)
            }
            return nil
        }
    }

    func createRecordingItem(from url: URL) -> RecordingItem? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = attrs[.size] as? Int64 ?? 0
        let date = attrs[.modificationDate] as? Date ?? Date()

        return RecordingItem(
            filename: url.lastPathComponent,
            path: url.path,
            date: date,
            size: size
        )
    }

    func createFolder(name: String) {
        let folderURL = baseURL.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadFolderStructure()
    }

    func getTotalStorageUsed() -> String {
        let fileManager = FileManager.default
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: baseURL, includingPropertiesForKeys: [.fileSizeKey], options: [])
        else {
            return "0 MB"
        }

        var totalSize: Int64 = 0
        for item in items {
            if let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        let mb = Double(totalSize) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Folder Tree View
struct FolderTreeView: View {
    @State var folder: FolderItem
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var folderManager: FolderManager
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Folder row
            HStack(spacing: 8) {
                Button(action: { folder.isExpanded.toggle() }) {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)

                Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)

                Text(folder.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovering ? .white : .primary)

                Spacer()

                Text("\(folder.recordings.count)")
                    .font(.system(size: 10, weight: .light))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovering ? Color.blue.opacity(0.2) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }

            // Expanded recordings
            if folder.isExpanded {
                ForEach(folder.recordings) { recording in
                    HStack(spacing: 8) {
                        Spacer()
                            .frame(width: 28)  // Indent for nested items

                        RecordingRowView(
                            recording: recording,
                            isPlaying: audioPlayer.currentPlayingFile == recording.filename,
                            audioPlayer: audioPlayer,
                            recordingsManager: recordingsManager
                        )
                    }
                }
            }
        }
    }
}

// MARK: - New Folder Dialog
struct NewFolderDialog: View {
    @Binding var folderName: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Folder")
                .font(.system(size: 16, weight: .semibold))

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onCreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - Recordings Sidebar
struct RecordingsSidebar: View {
    let recordings: [RecordingItem]
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @StateObject private var folderManager: FolderManager
    @State private var showNewFolderDialog = false
    @State private var newFolderName = ""
    @Binding var showAbout: Bool
    let openURL: (String) -> Void

    init(
        recordings: [RecordingItem], audioPlayer: AudioPlayer, recordingsManager: RecordingsManager,
        showAbout: Binding<Bool>, openURL: @escaping (String) -> Void
    ) {
        self.recordings = recordings
        self.audioPlayer = audioPlayer
        self.recordingsManager = recordingsManager
        self._showAbout = showAbout
        self.openURL = openURL

        // Initialize folder manager with lydfiler path
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let lydfilerPath = homeDir.appendingPathComponent("Desktop/lydfiler").path
        _folderManager = StateObject(wrappedValue: FolderManager(basePath: lydfilerPath))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Folder Tree & Recordings List
            if recordings.isEmpty && folderManager.folderStructure.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No recordings yet")
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Show folders first
                        ForEach(folderManager.folderStructure) { folder in
                            FolderTreeView(
                                folder: folder,
                                audioPlayer: audioPlayer,
                                recordingsManager: recordingsManager,
                                folderManager: folderManager
                            )
                        }

                        // Show root-level recordings (not in folders)
                        let rootRecordings = recordings.filter { recording in
                            !folderManager.folderStructure.contains { folder in
                                folder.recordings.contains { $0.path == recording.path }
                            }
                        }

                        ForEach(rootRecordings) { recording in
                            RecordingRowView(
                                recording: recording,
                                isPlaying: audioPlayer.currentPlayingFile == recording.filename,
                                audioPlayer: audioPlayer,
                                recordingsManager: recordingsManager
                            )
                        }
                    }
                }
            }

            Divider()

            // Footer with New Folder button and Storage stats
            VStack(spacing: 0) {
                // New Folder button
                Button(action: { showNewFolderDialog = true }) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12))
                        Text("New Folder")
                            .font(.system(size: 12, weight: .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Storage stats
                Text("Storage: \(folderManager.getTotalStorageUsed())")
                    .font(.system(size: 10, weight: .light))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)

                Divider()

                // VG JOJO Transcribe launcher
                Button(action: {
                    launchVGJOJOTranscribe()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(NAVColors.blue)
                        Text("VG JOJO Transcribe")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(NAVColors.textDefault)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(NAVColors.blue.opacity(0.05))
                }
                .buttonStyle(.plain)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        DispatchQueue.main.async { NSCursor.pointingHand.set() }
                    case .ended:
                        DispatchQueue.main.async { NSCursor.arrow.set() }
                    }
                }

                Divider()

                // Menu links
                VStack(alignment: .leading, spacing: 0) {
                    SidebarMenuItem(
                        icon: "link",
                        title: "Brukerinnsikt på Navet",
                        action: {
                            openURL(
                                "https://navno.sharepoint.com/sites/intranett-utvikling/SitePages/Brukerinnsikt.aspx"
                            )
                        }
                    )

                    SidebarMenuItem(
                        icon: "link",
                        title: "Brukerinnsikt på Aksel",
                        action: {
                            openURL("https://aksel.nav.no/god-praksis/brukerinnsikt")
                        }
                    )

                    Divider()
                        .padding(.vertical, 4)

                    SidebarMenuItem(
                        icon: "info.circle",
                        title: "About Virgin Project",
                        action: {
                            showAbout = true
                        }
                    )
                }

                // Version footer
                VStack(alignment: .leading, spacing: 4) {
                    Text("Virgin Project")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(NAVColors.textDefault)
                    Text("Version 0.2.0")
                        .font(.caption2)
                        .foregroundColor(NAVColors.textSubtle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color.white)
        }
        .background(Color.white)
        .onAppear {
            folderManager.loadFolderStructure()
        }
        .sheet(isPresented: $showNewFolderDialog) {
            NewFolderDialog(
                folderName: $newFolderName,
                onCreate: {
                    if !newFolderName.isEmpty {
                        folderManager.createFolder(name: newFolderName)
                        newFolderName = ""
                        showNewFolderDialog = false
                    }
                },
                onCancel: {
                    newFolderName = ""
                    showNewFolderDialog = false
                }
            )
        }
    }

    // VG JOJO Transcribe launcher function
    func launchVGJOJOTranscribe() {
        let workspace = NSWorkspace.shared
        let jojoPath = "/Applications/JOJO - Transcribe.app"

        if FileManager.default.fileExists(atPath: jojoPath) {
            workspace.open(URL(fileURLWithPath: jojoPath))
        } else {
            print("⚠️  VG JOJO Transcribe not found at: \(jojoPath)")
        }
    }
}

// MARK: - Icon Button with Stable Hover
struct IconButton: View {
    let action: () -> Void
    let icon: String
    let color: Color

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: "#E0E0E0"))  // Light grey circle
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color(hex: "#424242"))  // Dark grey icon
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                DispatchQueue.main.async { NSCursor.pointingHand.set() }
            case .ended:
                DispatchQueue.main.async { NSCursor.arrow.set() }
            }
        }
    }
}

// MARK: - Recording Row View
struct RecordingRowView: View {
    let recording: RecordingItem
    let isPlaying: Bool
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @State private var showDeleteConfirm = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Play button
            Button(action: {
                let url = URL(fileURLWithPath: recording.path)
                if isPlaying {
                    audioPlayer.togglePlayPause()
                } else {
                    audioPlayer.play(url: url)
                }
            }) {
                Image(systemName: isPlaying && audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(isHovering ? .white : (isPlaying ? .blue : .primary))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                case .ended:
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }

            // Recording info
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.filename)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .foregroundColor(isHovering ? .white : (isPlaying ? .blue : .primary))

                HStack(spacing: 6) {
                    Text(recording.formattedDate)
                        .font(.system(size: 10, weight: .light))
                    Text("•")
                        .font(.system(size: 8))
                    Text(recording.formattedSize)
                        .font(.system(size: 10, weight: .light))
                }
                .foregroundColor(isHovering ? .white.opacity(0.8) : .secondary)
            }

            Spacer()

            // Transcribe button
            IconButton(
                action: { openInJOJO() },
                icon: "doc.text",
                color: isHovering ? .white : .blue
            )

            // Delete button
            IconButton(
                action: { showDeleteConfirm = true },
                icon: "trash",
                color: isHovering ? .white : .red.opacity(0.8)
            )
            .alert("Delete Recording?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if isPlaying {
                        audioPlayer.stop()
                    }
                    recordingsManager.deleteRecording(recording)
                }
            } message: {
                Text("Are you sure you want to delete \(recording.filename)?")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovering ? Color.blue : (isPlaying ? Color.blue.opacity(0.05) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                DispatchQueue.main.async { NSCursor.pointingHand.set() }
            case .ended:
                DispatchQueue.main.async { NSCursor.arrow.set() }
            }
        }
        .contextMenu {
            Button(action: {
                openInJOJO()
            }) {
                Label("Open in JOJO Transcribe", systemImage: "doc.text")
            }

            Button(action: {
                NSWorkspace.shared.selectFile(recording.path, inFileViewerRootedAtPath: "")
            }) {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Divider()

            Button(
                role: .destructive,
                action: {
                    showDeleteConfirm = true
                }
            ) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Helper Functions
    func openInJOJO() {
        // Check if file exists
        guard FileManager.default.fileExists(atPath: recording.path) else {
            print("❌ File not found: \(recording.path)")
            return
        }

        print("🔍 Preparing JOJO for transcription: \(recording.filename)")

        // JOJO doesn't support programmatic file opening
        // So we: 1) Launch JOJO with a file to get the main window
        //        2) Open the lydfiler folder in Finder for easy access

        // Launch JOJO with the file (gets us past welcome screen even if file doesn't open)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Jojo", recording.path]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("⚠️ Error launching JOJO: \(error.localizedDescription)")
        }

        // Open the lydfiler folder in Finder
        let folderURL = URL(fileURLWithPath: recording.path).deletingLastPathComponent()
        NSWorkspace.shared.selectFile(recording.path, inFileViewerRootedAtPath: folderURL.path)

        print(
            "✅ Opened JOJO and lydfiler folder - drag \(recording.filename) into JOJO to transcribe"
        )
    }
}

// MARK: - Recording View
struct RecordingView: View {
    @ObservedObject var recorder: AudioRecorder
    @StateObject private var recordingsManager = RecordingsManager.shared
    @StateObject private var audioPlayer = AudioPlayer.shared
    @Binding var isShowing: Bool
    @State private var microphoneVerified = false
    @State private var verificationTimer: Timer?

    var body: some View {
        // Main recording area (sidebar is now global in MainView)
        mainRecordingView
            .onAppear {
                recordingsManager.loadRecordings()
                // Start audio monitoring to show waveform visualization
                recorder.startMonitoring()
                // Reset verification status
                microphoneVerified = false

                // Auto-verify after timeout (fallback if no audio detected)
                verificationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) {
                    _ in
                    if !microphoneVerified {
                        microphoneVerified = true
                    }
                }
            }
            .onDisappear {
                // Stop monitoring when leaving the recording view
                recorder.stopMonitoring()
                // Stop playback if active
                audioPlayer.stop()
                // Cancel verification timer
                verificationTimer?.invalidate()
            }
            .onChange(of: recorder.showSaveConfirmation) { _, showing in
                if !showing {
                    // Reload recordings when save confirmation disappears
                    recordingsManager.loadRecordings()
                }
            }
            .onChange(of: recorder.frequencyBands) { _, _ in
                // Auto-verify when audio is detected
                if !microphoneVerified {
                    let averageLevel =
                        recorder.frequencyBands.isEmpty
                        ? 0
                        : recorder.frequencyBands.reduce(0, +)
                            / Float(recorder.frequencyBands.count)
                    if averageLevel > 0.15 {
                        microphoneVerified = true
                        verificationTimer?.invalidate()
                    }
                }
            }
    }

    var mainRecordingView: some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack {
                Button(action: {
                    if recorder.isRecording {
                        recorder.stopRecording()
                    }
                    isShowing = false
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                        Text("Back")
                            .font(.title3)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .padding()
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        DispatchQueue.main.async { NSCursor.pointingHand.set() }
                    case .ended:
                        DispatchQueue.main.async { NSCursor.arrow.set() }
                    }
                }

                Spacer()

                Text("Voice Recorder")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                // Invisible button for balance
                Button(action: {}) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                        Text("Back")
                            .font(.title3)
                    }
                }
                .opacity(0)
                .disabled(true)
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Recording Interface
            ZStack {
                // Main Content
                VStack(spacing: 40) {
                    Spacer()

                    // Save Confirmation
                    if recorder.showSaveConfirmation {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 64, weight: .ultraLight))
                                .foregroundColor(.green)
                            Text("Recording Saved")
                                .font(.system(size: 24, weight: .light))
                            if let filename = recorder.lastSavedFile {
                                Text(filename)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(48)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(2)
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        // Microphone Icon with pulsing glow
                        VStack(spacing: 24) {
                            let averageLevel =
                                recorder.frequencyBands.isEmpty
                                ? 0
                                : recorder.frequencyBands.reduce(0, +)
                                    / Float(recorder.frequencyBands.count)
                            let amplifiedLevel = min(averageLevel * 3.0, 1.0)  // Increased amplification
                            let glowRadius = CGFloat(amplifiedLevel) * 30 + 10  // Larger glow range (10-40)
                            let glowOpacity = Double(amplifiedLevel) * 0.8 + 0.2  // More visible (0.2-1.0)

                            Image(
                                systemName: recorder.isRecording && !recorder.isPaused
                                    ? "mic.fill" : "mic"
                            )
                            .font(.system(size: 72, weight: .ultraLight))
                            .foregroundColor(
                                recorder.isRecording && !recorder.isPaused ? .red : .primary
                            )
                            .shadow(
                                color: (recorder.isRecording && !recorder.isPaused
                                    ? Color.red : Color.blue)
                                    .opacity(glowOpacity),
                                radius: glowRadius,
                                x: 0,
                                y: 0
                            )
                            .shadow(
                                color: (recorder.isRecording && !recorder.isPaused
                                    ? Color.red : Color.blue)
                                    .opacity(0.3),
                                radius: 15,
                                x: 0,
                                y: 0
                            )
                            .animation(.easeInOut(duration: 0.1), value: averageLevel)

                            // Recording Duration
                            if recorder.isRecording || recorder.recordingDuration > 0 {
                                Text(formatDuration(recorder.recordingDuration))
                                    .font(.system(size: 64, weight: .thin, design: .default))
                                    .foregroundColor(recorder.isPaused ? .orange : .primary)
                                    .tracking(2)
                                    .monospacedDigit()
                            }

                            // Status Text - minimal
                            if recorder.isPaused {
                                Text("Paused")
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundColor(.orange)
                                    .textCase(.uppercase)
                                    .tracking(2)
                            } else if recorder.isRecording {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 6, height: 6)
                                    Text("Recording")
                                        .font(.system(size: 14, weight: .light))
                                        .foregroundColor(.red)
                                        .textCase(.uppercase)
                                        .tracking(2)
                                }
                            }
                        }
                    }

                    Spacer()

                    // Control Buttons - Minimalist
                    if !recorder.showSaveConfirmation {
                        HStack(spacing: 32) {
                            // Delete Button (always show during recording)
                            if recorder.isRecording {
                                Button(action: {
                                    recorder.deleteCurrentRecording()
                                    isShowing = false
                                }) {
                                    VStack(spacing: 10) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 24, weight: .ultraLight))
                                            .foregroundColor(.red.opacity(0.8))
                                            .frame(width: 56, height: 56)
                                            .background(Color.red.opacity(0.08))
                                            .cornerRadius(2)
                                        Text("Delete")
                                            .font(.system(size: 11, weight: .light))
                                            .foregroundColor(.red.opacity(0.8))
                                            .textCase(.uppercase)
                                            .tracking(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            // Main Record/Stop Button
                            RecordButton(
                                isRecording: recorder.isRecording,
                                isVerified: microphoneVerified,
                                action: {
                                    if recorder.isRecording {
                                        recorder.stopRecording()
                                    } else {
                                        recorder.startRecording()
                                    }
                                }
                            )

                            // Pause/Resume Button (always show during recording)
                            if recorder.isRecording {
                                Button(action: {
                                    if recorder.isPaused {
                                        recorder.resumeRecording()
                                    } else {
                                        recorder.pauseRecording()
                                    }
                                }) {
                                    VStack(spacing: 10) {
                                        Image(systemName: recorder.isPaused ? "play" : "pause")
                                            .font(.system(size: 24, weight: .ultraLight))
                                            .foregroundColor(.orange.opacity(0.8))
                                            .frame(width: 56, height: 56)
                                            .background(Color.orange.opacity(0.08))
                                            .cornerRadius(2)
                                        Text(recorder.isPaused ? "Resume" : "Pause")
                                            .font(.system(size: 11, weight: .light))
                                            .foregroundColor(.orange.opacity(0.8))
                                            .textCase(.uppercase)
                                            .tracking(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 60)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let milliseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }

    func getSpectrumColor(for index: Int) -> Color {
        let ratio = Double(index) / 32.0
        if ratio < 0.33 {
            return .blue
        } else if ratio < 0.66 {
            return .green
        } else {
            return .red
        }
    }
}

// MARK: - About View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("About Virgin Project")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Version
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Version 0.2.0")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Purpose
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Purpose")
                            .font(.headline)
                        Text(
                            "Secure audio recording management for researchers conducting audio recordings on dedicated zero-trust Mac computers."
                        )
                        .font(.body)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Key Features
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key Features")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            FeatureRow(
                                icon: "shield.checkered",
                                text: "Automatic network isolation on launch")
                            FeatureRow(
                                icon: "mic.fill",
                                text: "Built-in voice recorder with waveform visualization")
                            FeatureRow(
                                icon: "sdcard.fill", text: "SD card auto-detection and import")
                            FeatureRow(
                                icon: "lock.shield", text: "Support for encrypted DS2 audio files")
                            FeatureRow(icon: "arrow.up.doc", text: "Secure file upload to Teams")
                        }
                    }

                    Divider()

                    // Security Information
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Security")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("• WiFi, Bluetooth, and AirDrop disabled on launch")
                            Text("• Network isolation maintained during recording")
                            Text("• Zero-trust environment design")
                            Text("• Dedicated machine requirement")
                            Text("• All file operations work offline")
                        }
                        .font(.body)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Usage Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick Start")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Record Audio")
                                .fontWeight(.semibold)
                            Text("   Click 'Record with Voice Recorder' to start")
                                .foregroundColor(.secondary)

                            Text("2. Import from SD Card")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Insert SD card with DS2 files from Olympus DS-9500")
                                .foregroundColor(.secondary)

                            Text("3. Transcribe")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Use VG JOJO Transcribe for transcription")
                                .foregroundColor(.secondary)

                            Text("4. Upload to Teams")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Enable network temporarily for secure upload")
                                .foregroundColor(.secondary)
                        }
                        .font(.body)
                    }

                    Divider()

                    // Technologies
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Technologies")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Swift 6.1+ & SwiftUI")
                            Text("• CoreWLAN & IOBluetooth for network control")
                            Text("• DiskArbitration for SD card detection")
                            Text("• AVFoundation for audio recording")
                            Text("• DSS Player for encrypted DS2 files")
                            Text("• VG JOJO Transcribe (NB-Whisper)")
                        }
                        .font(.body)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Contact & Support
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Contact & Support")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("For issues, questions, or feature requests:")
                            Text("• Refer to SPEC.md for complete specifications")
                            Text("• Check BACKLOG.md for planned features")
                            Text("• Review CHANGELOG.md for recent updates")
                        }
                        .font(.body)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Credits
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Credits")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Developed for NAV (Norwegian Labour and Welfare Administration)")
                                .fontWeight(.semibold)
                            Text("• NAV Design System (Aksel)")
                            Text("• OM System / Olympus (DSS Player)")
                            Text("• VG (JOJO Transcribe)")
                            Text("• National Library of Norway (NB-Whisper)")
                            Text("• OpenAI (Whisper ASR)")
                        }
                        .font(.body)
                        .foregroundColor(.secondary)
                    }

                    // Footer
                    Text("Copyright © 2025. All rights reserved.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                }
                .padding()
            }
        }
        .frame(width: 600, height: 700)
    }
}

// Helper view for feature rows with NAV styling
struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: NAVSpacing.sm) {
            Image(systemName: icon)
                .foregroundColor(NAVColors.blue)
                .frame(width: 20)
            Text(text)
                .font(.body)
                .foregroundColor(NAVColors.textSubtle)
        }
    }
}

// MARK: - Sidebar Panel
struct SidebarPanelContent: View {
    @Binding var showAbout: Bool
    @Binding var showSidebar: Bool
    let openURL: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Menu")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(NAVColors.textDefault)
                .padding()

            Divider()

            // Menu items
            VStack(alignment: .leading, spacing: 0) {
                SidebarMenuItem(
                    icon: "link",
                    title: "Brukerinnsikt på Navet",
                    action: {
                        openURL(
                            "https://navno.sharepoint.com/sites/intranett-utvikling/SitePages/Brukerinnsikt.aspx"
                        )
                    }
                )

                SidebarMenuItem(
                    icon: "link",
                    title: "Brukerinnsikt på Aksel",
                    action: {
                        openURL("https://aksel.nav.no/god-praksis/brukerinnsikt")
                    }
                )

                Divider()
                    .padding(.vertical, NAVSpacing.sm)

                SidebarMenuItem(
                    icon: "info.circle",
                    title: "About Virgin Project",
                    action: {
                        showSidebar = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showAbout = true
                        }
                    }
                )
            }

            Spacer()

            // Footer
            VStack(alignment: .leading, spacing: NAVSpacing.xs) {
                Text("Virgin Project")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(NAVColors.textDefault)
                Text("Version 0.2.0")
                    .font(.caption2)
                    .foregroundColor(NAVColors.textSubtle)
            }
            .padding()
        }
        .frame(width: 300, alignment: .leading)
        .background(NAVColors.bgDefault)
    }
}

// Helper view for sidebar menu items
struct SidebarMenuItem: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NAVSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(NAVColors.blue)
                    .frame(width: 20)
                Text(title)
                    .font(.body)
                    .foregroundColor(NAVColors.textDefault)
                Spacer()
            }
            .padding(.horizontal, NAVSpacing.lg)
            .padding(.vertical, NAVSpacing.md)
            .background(isHovered ? NAVColors.bgSubtle : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Main View
struct MainView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @StateObject private var fileManager = AudioFileManager.shared
    @StateObject private var sdCardManager = SDCardManager.shared
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var recordingsManager = RecordingsManager.shared
    @StateObject private var audioPlayer = AudioPlayer.shared
    @State private var showSuccessMessage = false
    @State private var successMessage = ""
    @State private var showImportSheet = false
    @State private var showRecordingView = false
    @State private var showAbout = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            RecordingsSidebar(
                recordings: recordingsManager.recordings,
                audioPlayer: audioPlayer,
                recordingsManager: recordingsManager,
                showAbout: $showAbout,
                openURL: openURL
            )
            .navigationTitle("All Recordings")
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            // Main content
            if showRecordingView {
                RecordingView(recorder: audioRecorder, isShowing: $showRecordingView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .navigationTitle("")
                    .toolbarBackground(.hidden, for: .windowToolbar)
            } else {
                mainContentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .navigationTitle("")
                    .toolbarBackground(.hidden, for: .windowToolbar)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 800)
        .sheet(isPresented: $showImportSheet) {
            SDCardImportView(sdCardManager: sdCardManager)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .onAppear {
            networkManager.updateStatus()
            recordingsManager.loadRecordings()
        }
    }

    var mainContentView: some View {
        VStack(spacing: 20) {
            // Header
            Text("Audio Recording Manager")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 10)

            // SD Card Detection Banner
            if sdCardManager.isSDCardInserted {
                HStack(spacing: NAVSpacing.md) {
                    Image(systemName: "sdcard.fill")
                        .font(.title2)
                        .foregroundColor(NAVColors.green)

                    VStack(alignment: .leading, spacing: NAVSpacing.xs) {
                        Text("SD CARD DETECTED")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(NAVColors.green)
                        if let volumeName = sdCardManager.sdCardVolumeName {
                            Text("Volume: \(volumeName)")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(NAVColors.textSubtle)
                        }
                        if let path = sdCardManager.sdCardPath {
                            Text("Path: \(path)")
                                .font(.system(size: 10, weight: .light))
                                .foregroundColor(NAVColors.textSubtle)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: NAVSpacing.xs) {
                        Text("\(sdCardManager.audioFiles.count) audio files")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(NAVColors.green)

                        Button(action: {
                            sdCardManager.ejectSDCard()
                        }) {
                            HStack(spacing: NAVSpacing.xs) {
                                Image(systemName: "eject")
                                    .font(.system(size: 10))
                                Text("Eject")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, NAVSpacing.md)
                            .padding(.vertical, NAVSpacing.xs + 1)
                            .background(NAVColors.green)
                            .foregroundColor(.white)
                            .cornerRadius(NAVRadius.medium)
                        }
                        .buttonStyle(.plain)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                DispatchQueue.main.async { NSCursor.pointingHand.set() }
                            case .ended:
                                DispatchQueue.main.async { NSCursor.arrow.set() }
                            }
                        }
                    }
                }
                .padding(NAVSpacing.lg)
                .background(NAVColors.green.opacity(0.1))
                .cornerRadius(NAVRadius.large)
                .overlay(
                    RoundedRectangle(cornerRadius: NAVRadius.large)
                        .stroke(NAVColors.green, lineWidth: 2)
                )
            }

            // Network Status Indicator - Centered
            HStack(spacing: 15) {
                NetworkStatusBadge(
                    label: "WiFi",
                    isEnabled: networkManager.wifiEnabled
                )
                NetworkStatusBadge(
                    label: "Bluetooth",
                    isEnabled: networkManager.bluetoothEnabled
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 10)

            Divider()
                .padding(.vertical, 10)

            // Success Message
            if showSuccessMessage {
                Text(successMessage)
                    .font(.title2)
                    .foregroundColor(.green)
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
            }

            // Main Action Buttons
            VStack(spacing: NAVSpacing.lg) {
                Button(action: {
                    launchVoiceRecorder()
                }) {
                    HStack(spacing: NAVSpacing.md) {
                        Image(systemName: "mic.fill")
                            .font(.title)
                            .foregroundColor(.white)
                        Text("Record with Voice Recorder")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(NAVPrimaryButtonStyle())

                Button(action: {
                    importFromSDCard()
                }) {
                    HStack(spacing: NAVSpacing.md) {
                        Image(systemName: "sdcard.fill")
                            .font(.title)
                        Text("Import Audio from SD Card")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(NAVPrimaryButtonStyle())
            }
            .padding(.vertical, NAVSpacing.xl)

            Divider()

            // Network Controls
            VStack(spacing: 15) {
                Button(action: {
                    uploadToTeams()
                }) {
                    HStack(spacing: NAVSpacing.sm) {
                        Image(systemName: "arrow.up.doc.fill")
                            .foregroundColor(.white)
                        Text("Upload to Teams")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        DispatchQueue.main.async {
                            NSCursor.pointingHand.set()
                        }
                    case .ended:
                        DispatchQueue.main.async {
                            NSCursor.arrow.set()
                        }
                    }
                }

                Button(action: {
                    toggleNetworkOverride()
                }) {
                    HStack {
                        if DEMO_MODE {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                        Image(
                            systemName: networkManager.isNetworkOverrideActive
                                ? "wifi.slash" : "wifi")
                        Text(
                            DEMO_MODE
                                ? "DEMO MODE"
                                : (networkManager.isNetworkOverrideActive
                                    ? "Disable Network" : "Enable Network (Override)")
                        )
                        .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(
                    DEMO_MODE ? .orange : (networkManager.isNetworkOverrideActive ? .red : .orange)
                )
                .disabled(DEMO_MODE)
                .onContinuousHover { phase in
                    if !DEMO_MODE {
                        switch phase {
                        case .active:
                            DispatchQueue.main.async {
                                NSCursor.pointingHand.set()
                            }
                        case .ended:
                            DispatchQueue.main.async {
                                NSCursor.arrow.set()
                            }
                        }
                    }
                }
            }

            Spacer()

            // NAV Logo - Bottom Center
            if let resourcePath = Bundle.main.resourcePath {
                let logoName =
                    NSApp.effectiveAppearance.name == .darkAqua ? "nav-white.png" : "nav-grey.png"
                if let nsImage = NSImage(
                    contentsOfFile: (resourcePath as NSString).appendingPathComponent(logoName))
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 70, height: 21)
                        .opacity(0.7)
                        .padding(.bottom, 15)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 30)
        .padding(.bottom, 20)
    }

    // MARK: - Actions

    func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func launchVoiceRecorder() {
        // Show custom recording view
        showRecordingView = true
    }

    func importFromSDCard() {
        // Launch DSS Player and show import sheet
        sdCardManager.launchDSSPlayer()
        showImportSheet = true
    }

    func uploadToTeams() {
        // Enable only WiFi (Teams doesn't need Bluetooth)
        networkManager.enableWiFi()

        let workspace = NSWorkspace.shared

        // Launch Microsoft Teams
        if let teamsURL = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.teams2")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.microsoft.teams")
        {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: teamsURL, configuration: configuration) { app, error in
                if let error = error {
                    print("Failed to launch Teams: \(error)")
                }
            }
        } else {
            print("Microsoft Teams not found")
        }

        // Open Finder to lydfiler folder
        let folderURL = URL(fileURLWithPath: fileManager.audioFolderPath)
        workspace.selectFile(nil, inFileViewerRootedAtPath: folderURL.path)

        // Also open OneDrive folder in a separate window
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let oneDrivePaths = [
            homeDir.appendingPathComponent("OneDrive").path,
            homeDir.appendingPathComponent("Library/CloudStorage/OneDrive-Personal").path,
            homeDir.appendingPathComponent("OneDrive - Personal").path,
        ]

        for path in oneDrivePaths {
            if FileManager.default.fileExists(atPath: path) {
                // Open OneDrive in new Finder window
                workspace.open(URL(fileURLWithPath: path))
                break
            }
        }

        // Show message
        showSuccess(
            message:
                "Network enabled. Teams launched. Upload your files, then click 'Disable Network' when done."
        )
    }

    func toggleNetworkOverride() {
        if networkManager.isNetworkOverrideActive {
            networkManager.disableAllConnections()
            networkManager.isNetworkOverrideActive = false
            showSuccess(message: "Network disabled for security")
        } else {
            networkManager.enableAllConnections()
            showSuccess(message: "Network override active")
        }
    }

    func showSuccess(message: String) {
        successMessage = message
        showSuccessMessage = true

        // Hide message after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            showSuccessMessage = false
        }
    }
}

// MARK: - SD Card Import View
struct SDCardImportView: View {
    @ObservedObject var sdCardManager: SDCardManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFiles: Set<AudioFileInfo> = []
    @State private var isImporting = false
    @State private var importProgress = 0.0
    @State private var importedCount = 0
    @State private var importedFiles: [AudioFileInfo] = []
    @State private var showDeletePrompt = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Import Audio from SD Card")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            // SD Card Status
            if sdCardManager.isSDCardInserted {
                HStack {
                    Image(systemName: "sdcard.fill")
                        .foregroundColor(.green)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("SD Card: \(sdCardManager.sdCardVolumeName ?? "Unknown")")
                            .font(.headline)
                        Text("\(sdCardManager.audioFiles.count) audio files found")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if sdCardManager.isScanning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button(action: {
                            sdCardManager.ejectSDCard()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "eject")
                                Text("Eject")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                DispatchQueue.main.async { NSCursor.pointingHand.set() }
                            case .ended:
                                DispatchQueue.main.async { NSCursor.arrow.set() }
                            }
                        }
                    }
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                HStack {
                    Image(systemName: "sdcard")
                        .foregroundColor(.orange)
                        .font(.title2)
                    Text("No SD Card detected. Please insert an Olympus SD card.")
                        .font(.headline)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if !sdCardManager.audioFiles.isEmpty {
                // Selection Controls
                HStack {
                    Button(
                        selectedFiles.count == sdCardManager.audioFiles.count
                            ? "Deselect All" : "Select All"
                    ) {
                        if selectedFiles.count == sdCardManager.audioFiles.count {
                            selectedFiles.removeAll()
                        } else {
                            selectedFiles = Set(sdCardManager.audioFiles)
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("\(selectedFiles.count) of \(sdCardManager.audioFiles.count) selected")
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                // File List
                List(sdCardManager.audioFiles, id: \.self, selection: $selectedFiles) { file in
                    FileRowView(file: file, isSelected: selectedFiles.contains(file))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedFiles.contains(file) {
                                selectedFiles.remove(file)
                            } else {
                                selectedFiles.insert(file)
                            }
                        }
                }
                .frame(maxHeight: 400)

                // Import Progress
                if isImporting {
                    VStack {
                        ProgressView(value: importProgress, total: Double(selectedFiles.count))
                        Text("Importing \(importedCount) of \(selectedFiles.count) files...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }

                // Import Button
                Button(action: {
                    importSelectedFiles()
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text(
                            "Import \(selectedFiles.count) File\(selectedFiles.count == 1 ? "" : "s")"
                        )
                        .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFiles.isEmpty || isImporting)
                .padding(.horizontal)
            }

            Spacer()
        }
        .frame(width: 700, height: 600)
    }

    func importSelectedFiles() {
        isImporting = true
        importedCount = 0
        importProgress = 0

        let filesToImport = Array(selectedFiles)
        let fileManager = FileManager.default
        let audioFolder = AudioFileManager.shared.audioFolderPath

        for file in filesToImport {
            // Use ORIGINAL filename, not a generated timestamp
            var destinationPath = (audioFolder as NSString).appendingPathComponent(file.name)

            // If file already exists, add a number suffix
            var counter = 1
            while fileManager.fileExists(atPath: destinationPath) {
                let nameWithoutExt = (file.name as NSString).deletingPathExtension
                let ext = (file.name as NSString).pathExtension
                let newName = "\(nameWithoutExt)_\(counter).\(ext)"
                destinationPath = (audioFolder as NSString).appendingPathComponent(newName)
                counter += 1
            }

            do {
                // Copy file with original name
                try fileManager.copyItem(atPath: file.path, toPath: destinationPath)
                let finalName = (destinationPath as NSString).lastPathComponent
                print("✅ Imported: \(file.name) → \(finalName)")

                importedCount += 1
                importProgress = Double(importedCount)
            } catch {
                print("❌ Failed to import \(file.name): \(error)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isImporting = false
            if importedCount > 0 {
                // Success! Show completion
                print("🎉 Imported \(importedCount) files successfully")
                dismiss()
            }
        }
    }
}

// MARK: - File Row View
struct FileRowView: View {
    let file: AudioFileInfo
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .blue : .gray)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.headline)
                HStack {
                    Text(file.formattedSize)
                    Text("•")
                    Text(file.formattedDate)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Network Status Badge
struct NetworkStatusBadge: View {
    let label: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isEnabled ? Color.green : Color.red)
                .frame(width: 12, height: 12)

            Text(label)
                .font(.headline)

            Text(isEnabled ? "ON" : "OFF")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(isEnabled ? .green : .red)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(20)
    }
}
