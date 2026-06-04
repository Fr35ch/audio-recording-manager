import AVFAudio
import AVFoundation
import Accelerate
import CoreAudio
import CoreMedia
import DiskArbitration
import Foundation
import SwiftUI

// MARK: - Design System
// Design tokens (AppColors, AppSpacing, AppRadius) have been extracted to
// `Design/DesignTokens.swift`. Glass styles (GlassButtonStyle,
// HoverButtonStyle, glassEffectIfAvailable) are in `Design/GlassStyles.swift`.
// Window chrome is documented in `Design/WindowChrome.swift`.
// See `Design/README.md` for the rules around that folder.

// MARK: - App Entry Point
struct ClioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Default WindowGroup — SwiftUI auto-opens this on launch.
        // AppDelegate immediately hides it, shows the chromeless splash,
        // then fades this window back in after startup completes.
        WindowGroup {
            MainView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tint(AppColors.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)

        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .help) {
                Button("Loggvisning") {
                    NotificationCenter.default.post(name: .init("ClioShowLogViewer"), object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Design system") {
                    NotificationCenter.default.post(name: .init("ClioShowDesignShowcase"), object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Innstillinger …") {
                    NotificationCenter.default.post(name: .init("ClioShowSettings"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // Secondary scene: transcript editor opens here as its own macOS
        // window, keyed by recording id. SwiftUI dedupes by `value:` so
        // double-opening the same recording brings the existing window to
        // front instead of duplicating.
        WindowGroup(id: "transcript-editor", for: UUID.self) { $recordingId in
            if let id = recordingId {
                TranscriptEditorWindow(recordingId: id)
                    .tint(AppColors.accent)
            }
        }
        .defaultSize(width: 1200, height: 800)
    }
}

// MARK: - App Delegate for Launch Configuration
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Held strongly so the notification observer survives.
    private var toolbarObserver: NSObjectProtocol?

    private let splashController   = SplashWindowController()
    private let startupCoordinator = StartupCoordinator()
    private var mainWindow: NSWindow?
    private var splashShown = false   // fix 4 — guard against multiple splash windows

    func applicationWillFinishLaunching(_ notification: Notification) {}

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !splashShown else { return }   // fix 4
        splashShown = true
        print("✅ App delegate did finish launching")

        // Register default values so UserDefaults.standard.integer(forKey:)
        // returns the correct fallback even before the user opens Settings.
        UserDefaults.standard.register(defaults: [
            "transcription.defaultModel":    TranscriptionModel.large.rawValue,
            "transcription.defaultSpeakers": 2,
            "transcription.verbatim":        false,
            "transcription.language":        "no",
            "transcription.validateMode":    "warn",
            "transcription.numBeams":        3,
            "analysis.llmModel":             LLMModel.defaultModel.rawValue,
            "beta.enabled":                  false,
        ])

        // Ensure storage directories exist
        try? StorageLayout.ensureDirectoriesExist()

        // 30-day retention: DISABLED until grace period logic is added.
        // Enabling this without a grace period would retroactively delete
        // all pre-existing recordings whose createdAt is older than 30 days,
        // which is destructive for migrated recordings that were never
        // subject to a 30-day policy. The expiry manager itself is ready
        // (RecordingExpiryManager.swift) — it just needs a "policy start
        // date" check so recordings created before the feature was enabled
        // get a fresh 30-day window from their first launch under the new
        // policy, not from their original createdAt.
        // RecordingExpiryManager.shared.checkAndExpire()

        // Ensure the app appears in the Dock and App Switcher
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Store and hide the SwiftUI main window — it will be faded in
        // by revealMainWindow() after the splash completes.
        mainWindow = mainWindows().first
        mainWindow?.orderOut(nil)

        // Show the chromeless splash and kick off startup checks.
        splashController.onDismiss = { [weak self] in self?.revealMainWindow() }
        splashController.show(coordinator: startupCoordinator)

        // Kick off the startup sequence (drives the splash status line).
        Task { await startupCoordinator.runStartupSequence() }

        // Auto-install no-transcribe in the background if not already present
        Task {
            await TranscriptionService.shared.setupIfNeeded()
        }

        // Disable NSToolbar user customisation on every window. The
        // chrome trigger we add in `ClioApp.body` (a
        // zero-size `.principal` toolbar item — required for
        // `.windowToolbarStyle(.unified(showsTitle: false))` to
        // engage) keeps surfacing a visible button next to the
        // traffic lights because NSToolbar dresses it up as a
        // display-mode picker. Suppressing customisation removes
        // the picker (and with it the button itself).
        //
        // This is AppKit toolbar configuration. The Design rule-2
        // ban on AppDelegate AppKit work is specifically about four
        // NSWindow properties (titlebarAppearsTransparent,
        // fullSizeContentView, titleVisibility, styleMask) — NSToolbar
        // is a separate object and not on the ban-list. Documented
        // in `Design/README.md` alongside the rest of the chrome
        // pipeline.
        toolbarObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }

            // SwiftUI adds toolbar items asynchronously after the window
            // becomes key, so deferring to the next run-loop pass ensures
            // the sidebar-toggle item exists before we try to remove it.
            // Without this delay the cleanup runs on first launch before
            // the items are populated, leaving the button visible until
            // the next activation cycle.
            DispatchQueue.main.async {
                guard let toolbar = window.toolbar else { return }
                toolbar.allowsUserCustomization = false
                toolbar.autosavesConfiguration = false
                toolbar.displayMode = .iconOnly

                // Diagnostic + corrective: log every toolbar item we see
                // so we can target precisely if the heuristic below
                // doesn't match, then remove anything that looks like a
                // sidebar toggle. Apple keeps these identifiers private
                // ("com.apple.SwiftUI.…" style) so we match heuristically
                // on the substring rather than hard-coding a constant.
                let items = toolbar.items
                if !items.isEmpty {
                    let ids = items.map { $0.itemIdentifier.rawValue }.joined(separator: ", ")
                    print("ARM toolbar items for window \(window.title.isEmpty ? "<untitled>" : window.title): \(ids)")
                }
                for index in stride(from: items.count - 1, through: 0, by: -1) {
                    let id = items[index].itemIdentifier.rawValue
                    if id.localizedCaseInsensitiveContains("togglesidebar")
                        || id.localizedCaseInsensitiveContains("sidebartoggle")
                        || id.localizedCaseInsensitiveContains("sidebartracking")
                        || id.localizedCaseInsensitiveContains("toggle sidebar")
                    {
                        toolbar.removeItem(at: index)
                        print("ARM: removed toolbar item \(id)")
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    private func revealMainWindow() {
        guard let win = mainWindow else { return }
        win.alphaValue = 0
        win.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            win.animator().alphaValue = 1
        }
    }

    private func mainWindows() -> [NSWindow] {
        // Fix 3 — filter by identity, not by window level (level can be reset by system)
        NSApp.windows.filter { $0 !== splashController.window && !($0 is NSPanel) }
    }
}

// AudioFileManager deleted — all storage now goes through RecordingStore.
// See ADR-1014 and Phase 0 tasks D5/D6.









// MARK: - Glass Effect Helpers
// `glassEffectIfAvailable`, `GlassButtonStyle`, and `HoverButtonStyle` have
// been extracted to `Design/GlassStyles.swift`. See `Design/README.md`.

// MARK: - Cursor Modifier
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.background(
            GeometryReader { geometry in
                CursorHostingView(cursor: cursor, frame: geometry.frame(in: .local))
            }
        )
    }

    func introspectSplitView(customize: @escaping (NSSplitView) -> Void) -> some View {
        self.background(
            SplitViewIntrospector(customize: customize)
        )
    }
}

// MARK: - SplitView Introspector
struct SplitViewIntrospector: NSViewRepresentable {
    let customize: (NSSplitView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let splitView = self.findSplitView(in: view) {
                self.customize(splitView)
                // Set delegate to prevent resizing
                splitView.delegate = context.coordinator
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func findSplitView(in view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let parent = current?.superview {
            if let splitView = parent as? NSSplitView {
                return splitView
            }
            current = parent
        }
        return nil
    }

    class Coordinator: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            return false
        }

        func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
            return true
        }

        func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            // Return zero rect to make divider non-interactive
            return .zero
        }
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
                    // Stop button with Liquid Glass styling
                    VStack(spacing: AppSpacing.sm) {
                        Rectangle()
                            .fill(AppColors.destructive)
                            .frame(width: 56, height: 56)
                            .cornerRadius(AppRadius.small)
                        Text("Stopp")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColors.destructive)
                            .textCase(.uppercase)
                            .tracking(1)
                    }
                } else if isVerified {
                    // Start Recording button with glass effect
                    Text("Start Opptak")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .tracking(0.5)
                        .padding(.horizontal, AppSpacing.xxl + AppSpacing.sm)
                        .padding(.vertical, AppSpacing.lg + 2)
                        .background(isHovering ? AppColors.destructive.opacity(0.85) : AppColors.destructive)
                        .cornerRadius(AppRadius.large)
                        .animation(.easeInOut(duration: 0.15), value: isHovering)
                } else {
                    // Verifying state - grey/disabled
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .colorScheme(.dark)
                        Text("Verifiserer mikrofon")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .tracking(0.5)
                    }
                    .padding(.horizontal, AppSpacing.xxl + AppSpacing.sm)
                    .padding(.vertical, AppSpacing.lg + 2)
                    .background(Color.gray.opacity(0.5))
                    .cornerRadius(AppRadius.large)
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
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(AppRadius.medium)
                }
                .buttonStyle(.plain)
                .help("Lydinnstillinger")
                .popover(isPresented: $showAudioSourceMenu, arrowEdge: .bottom) {
                    AudioSourceSelector()
                }
            }
        }
    }
}

// MARK: - Audio Source Selector

private struct AudioDevice: Identifiable {
    let id: AudioDeviceID
    let name: String
}

/// Only physical/hardware input devices. Excludes virtual, aggregate, AirPlay,
/// network, and Continuity Camera (AVB) sources.
private let physicalTransportTypes: Set<UInt32> = [
    kAudioDeviceTransportTypeBuiltIn,
    kAudioDeviceTransportTypeUSB,
    kAudioDeviceTransportTypeFireWire,
    kAudioDeviceTransportTypeBluetooth,
    kAudioDeviceTransportTypeBluetoothLE,
    kAudioDeviceTransportTypeThunderbolt,
    kAudioDeviceTransportTypePCI,
    kAudioDeviceTransportTypeHDMI,
    kAudioDeviceTransportTypeDisplayPort,
]

struct AudioSourceSelector: View {
    @State private var audioDevices: [AudioDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lydkilde")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                let devices = audioDevices.isEmpty ? [AudioDevice(id: 0, name: "Innebygd mikrofon")] : audioDevices
                ForEach(devices) { device in
                    AudioDeviceRow(device: device, recorder: AudioRecorder.shared)
                }
            }

            Divider()

            Text("Kun fysiske lydinngangsenheter vises")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: 250)
        .onAppear { loadAudioDevices() }
    }
}

private struct AudioDeviceRow: View {
    let device: AudioDevice
    @ObservedObject var recorder: AudioRecorder  // holds for re-render only

    var body: some View {
        let isSelected = AudioRecorder.shared.selectedInputDeviceID == device.id
        Button(action: { AudioRecorder.shared.setInputDevice(device.id) }) {
            HStack {
                Text(device.name)
                    .font(.system(size: 13))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
    }
}

// Methods below belong to AudioSourceSelector (extracted here to avoid
// compiler type-check timeout on the body expression).
extension AudioSourceSelector {
    func loadAudioDevices() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr else { return }

        var result: [AudioDevice] = []
        for id in ids {
            guard hasInputStream(id), isPhysicalDevice(id), let name = deviceName(id) else { continue }
            result.append(AudioDevice(id: id, name: name))
        }
        audioDevices = result
    }

    private func hasInputStream(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr && size > 0
    }

    private func isPhysicalDevice(_ deviceID: AudioDeviceID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return physicalTransportTypes.contains(transport)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var nameRef: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &nameRef) == noErr else { return nil }
        return nameRef as String
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
    @Published var rootRecordings: [RecordingItem] = []
    private let baseURL: URL

    // File system monitoring
    private var fileDescriptors: [Int32] = []
    private var dispatchSources: [DispatchSourceFileSystemObject] = []
    private var reloadWorkItem: DispatchWorkItem?

    init(basePath: String) {
        self.baseURL = URL(fileURLWithPath: basePath)
        loadFolderStructure()
        startWatchingFolders()
    }

    deinit {
        stopWatchingFolders()
    }

    /// Start monitoring the base folder and all subfolders for changes
    private func startWatchingFolders() {
        // Watch the base folder
        watchFolder(at: baseURL.path)

        // Watch all subfolders
        let fileManager = FileManager.default
        if let items = try? fileManager.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        {
            for item in items {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    watchFolder(at: item.path)
                }
            }
        }
        print("👁️ Watching \(dispatchSources.count) folders for changes")
    }

    /// Watch a single folder for changes
    private func watchFolder(at path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("⚠️ Could not open folder for monitoring: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }

        source.setCancelHandler {
            close(fd)
        }

        fileDescriptors.append(fd)
        dispatchSources.append(source)
        source.resume()
    }

    /// Debounced reload to handle rapid file system changes
    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            print("📁 Folder structure changed, reloading...")
            self?.loadFolderStructure()
            // Also reload the shared RecordingsManager
            RecordingsManager.shared.loadRecordings()
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// Stop monitoring all folders
    private func stopWatchingFolders() {
        for source in dispatchSources {
            source.cancel()
        }
        dispatchSources.removeAll()
        fileDescriptors.removeAll()
        reloadWorkItem?.cancel()
    }

    /// Refresh watchers when folder structure changes (e.g., new folder created)
    private func refreshWatchers() {
        stopWatchingFolders()
        startWatchingFolders()
    }

    func loadFolderStructure() {
        let fileManager = FileManager.default
        let previousFolderCount = folderStructure.count

        // Get all items in recordings folder
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: baseURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else {
            return
        }

        var folders: [FolderItem] = []
        var newRootRecordings: [RecordingItem] = []

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
                    newRootRecordings.append(recording)
                }
            }
        }

        // Sort folders alphabetically
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Sort root recordings by date, newest first
        newRootRecordings.sort { $0.date > $1.date }

        // Update published properties
        folderStructure = folders
        rootRecordings = newRootRecordings

        print("📁 Loaded \(folders.count) folders, \(newRootRecordings.count) root recordings")

        // If folder count changed, refresh watchers to include new folders
        if folders.count != previousFolderCount {
            refreshWatchers()
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

        let audioFile = try? AVAudioFile(forReading: url)
        let audioDuration = audioFile.map {
            Double($0.length) / $0.processingFormat.sampleRate
        } ?? 0

        // Derive stable ID from the parent folder UUID (Phase 0 layout)
        // or generate a deterministic one from the path for legacy items.
        let stableId = StorageLayout.recordingId(from: url.deletingLastPathComponent())
            ?? UUID(uuidString: url.path.hash.description)
            ?? UUID()

        return RecordingItem(
            id: stableId,
            filename: url.lastPathComponent,
            path: url.path,
            date: date,
            size: size,
            duration: audioDuration.isNaN ? 0 : audioDuration
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
    let folderPath: String
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var folderManager: FolderManager
    @State private var isHovering = false
    @State private var isExpanded = false

    // Get the current folder data from folderManager (always up-to-date)
    private var folder: FolderItem? {
        folderManager.folderStructure.first { $0.path == folderPath }
    }

    var body: some View {
        if let folder = folder {
            VStack(spacing: 0) {
                // Folder row
                HStack(spacing: 8) {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)

                    Text(folder.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovering ? .white : .primary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isHovering ? Color.blue.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovering = hovering
                }

                // Expanded recordings
                if isExpanded {
                    ForEach(folder.recordings) { recording in
                        HStack(spacing: 8) {
                            Spacer()
                                .frame(width: 28)  // Indent for nested items

                            RecordingRowView(
                                recording: recording,
                                isPlaying: audioPlayer.currentPlayingURL == recording.audioURL && audioPlayer.isPlaying,
                                audioPlayer: audioPlayer,
                                recordingsManager: recordingsManager
                            )
                        }
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
                .font(.system(size: 15, weight: .semibold))

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onCreate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

// MARK: - Anonymization Reminder Dialog
struct AnonymizationReminderDialog: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.warning)

                Text("Before uploading")
                    .font(.system(size: 18, weight: .semibold))

                Text("Check that the text is anonymized")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // Checklist
            VStack(alignment: .leading, spacing: 10) {
                ChecklistItem(text: "Remove names, contact info, and ID numbers")
                ChecklistItem(text: "Remove names of family, friends, and NAV employees")
                ChecklistItem(text: "Remove health information that could identify the participant")
                ChecklistItem(text: "Use codes like P1, P2, etc. instead of names")
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button(action: onContinue) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.doc.fill")
                        Text("Continue to Teams")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}

// Helper view for checklist items
struct ChecklistItem: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(AppColors.success)
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Recordings Sidebar
// MARK: - Audio Waveform Icon (Custom SVG)
struct AudioWaveformIcon: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Canvas { context, size in
            let fillColor = colorScheme == .dark ? Color.white : Color(red: 32/255, green: 39/255, blue: 51/255)

            // Scale factor to fit 431.77x233.48 viewBox into the given size
            let scale = min(size.width / 431.77, size.height / 233.48)
            let xOffset = (size.width - 431.77 * scale) / 2
            let yOffset = (size.height - 233.48 * scale) / 2

            context.translateBy(x: xOffset, y: yOffset)
            context.scaleBy(x: scale, y: scale)

            // Bar 1: Medium height (left)
            context.fill(
                Path(roundedRect: CGRect(x: 0, y: 50.61, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 2: Short height
            context.fill(
                Path(roundedRect: CGRect(x: 50.11, y: 0, width: 31.11, height: 152.59), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 3: Medium height
            context.fill(
                Path(roundedRect: CGRect(x: 100.22, y: 50.61, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 4: Full height (tallest)
            context.fill(
                Path(roundedRect: CGRect(x: 150.72, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 5: Short height (center)
            context.fill(
                Path(roundedRect: CGRect(x: 200.83, y: 0, width: 31.11, height: 152.59), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 6: Medium height
            context.fill(
                Path(roundedRect: CGRect(x: 250.94, y: 50.6, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 7: Full height (tallest)
            context.fill(
                Path(roundedRect: CGRect(x: 300.44, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 8: Very short height
            context.fill(
                Path(roundedRect: CGRect(x: 350.55, y: 50.6, width: 31.11, height: 101.99), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 9: Full height (tallest, right)
            context.fill(
                Path(roundedRect: CGRect(x: 400.66, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )
        }
        .aspectRatio(431.77/233.48, contentMode: .fit)
    }
}

// MARK: - Navigation Panel (left-most narrow column)
struct NavPanel: View {
    @Binding var selectedTab: AppTab
    @Binding var showAbout: Bool

    @State private var isDarkMode: Bool = NSApp.effectiveAppearance.name == .darkAqua

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            VStack(spacing: 4) {
                navItem(tab: .record, label: "Ta opp lyd", icon: "mic.fill")
                navItem(tab: .recordings, label: "Bibliotek", icon: "books.vertical.fill")
                navItem(tab: .analyse, label: "Analyser", icon: "brain.head.profile")
            }
            .padding(.horizontal, 6)
            .padding(.top, 20)

            Spacer()

            Divider().padding(.horizontal, 6)
            footerBlock
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var footerBlock: some View {
        VStack(spacing: 4) {
            footerIconButton(
                icon: isDarkMode ? "sun.max" : "moon",
                helpText: isDarkMode ? "Light mode" : "Dark mode",
                action: toggleAppearance
            )
            footerIconButton(
                icon: "gearshape",
                helpText: "Innstillinger",
                action: {
                    NotificationCenter.default.post(
                        name: .init("ClioShowSettings"), object: nil)
                }
            )
            footerIconButton(
                icon: "info.circle",
                helpText: "Om Clio",
                action: { showAbout = true }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func footerIconButton(icon: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FooterIconButtonLabel(icon: icon, helpText: helpText)
        }
        .buttonStyle(.plain)
    }

    private func toggleAppearance() {
        isDarkMode.toggle()
        NSApp.appearance = isDarkMode
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }

    private func navItem(tab: AppTab, label: String, icon: String) -> some View {
        Button(action: { selectedTab = tab }) {
            NavItemLabel(tab: tab, selectedTab: selectedTab, icon: icon, label: label)
        }
        .buttonStyle(.plain)
    }
}

// Extracted to a struct so @State for hover can be used (functions can't hold @State).
private struct NavItemLabel: View {
    let tab: AppTab
    let selectedTab: AppTab
    let icon: String
    let label: String

    @State private var isHovered = false

    private var isActive: Bool { selectedTab == tab }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: isActive ? .semibold : .regular))
            .frame(width: 44, height: 36)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.small)
                    .fill(isActive
                        ? AppColors.accent.opacity(0.18)
                        : isHovered
                            ? AppColors.accent.opacity(0.09)
                            : Color.clear
                    )
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .foregroundStyle(isActive
                ? AppColors.accent
                : isHovered
                    ? AppColors.accent.opacity(0.75)
                    : Color.secondary
            )
            .contentShape(Rectangle())
            .help(label)
            .onHover { hovering in
                isHovered = hovering
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
    }
}

private struct FooterIconButtonLabel: View {
    let icon: String
    let helpText: String

    @State private var isHovered = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .frame(width: 44, height: 36)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.small)
                    .fill(isHovered ? AppColors.accent.opacity(0.09) : Color.clear)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .foregroundStyle(isHovered ? AppColors.accent.opacity(0.75) : Color.secondary)
            .contentShape(Rectangle())
            .help(helpText)
            .onHover { hovering in
                isHovered = hovering
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
    }
}

// MARK: - Recordings Native View (macOS Glass Design)

// MARK: - Recordings List Column (content column for 3-column split)

struct RecordingsListColumn: View {
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var audioPlayer: AudioPlayer
    @Binding var selectedRecording: RecordingItem?

    var body: some View {
        List(selection: $selectedRecording) {
            ForEach(recordingsManager.recordings) { recording in
                RecordingListRow(
                    recording: recording,
                    isPlaying: audioPlayer.currentPlayingURL == recording.audioURL && audioPlayer.isPlaying,
                    audioPlayer: audioPlayer,
                    recordingsManager: recordingsManager
                )
                .tag(recording)
                .listRowSeparator(.visible)
            }
        }
    }
}

// MARK: - Recording List Row

struct RecordingListRow: View {
    let recording: RecordingItem
    let isPlaying: Bool
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @State private var showDeleteConfirm = false
    @State private var isHovering = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.filename)
                    .font(.body)
                HStack(spacing: 4) {
                    Text(recording.formattedDate)
                    Text("·")
                    Text(recording.formattedDuration)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: isPlaying ? "waveform" : "waveform.circle")
                .font(.title3)
                .foregroundStyle(isPlaying ? .blue : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        }
        .listRowBackground(
            isHovering ? Color(nsColor: .controlAccentColor).opacity(0.1) : Color.clear
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button {
                let url = recording.audioURL
                if isPlaying {
                    audioPlayer.togglePlayPause()
                } else {
                    audioPlayer.play(url: url)
                }
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }

            Divider()

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Slett", systemImage: "trash")
            }
        }
        .alert("Slett opptak?", isPresented: $showDeleteConfirm) {
            Button("Avbryt", role: .cancel) {}
            Button("Slett", role: .destructive) {
                if isPlaying { audioPlayer.stop() }
                recordingsManager.deleteRecording(recording)
            }
        } message: {
            Text("Er du sikker på at du vil slette \(recording.filename)?")
        }
    }
}

// MARK: - Recording Player (Native)

struct RecordingPlayerNative: View {
    let recording: RecordingItem
    @ObservedObject var audioPlayer: AudioPlayer
    var onNavigateToTranscript: ((UUID) -> Void)?

    // Scrubber state
    @State private var isDraggingScrubber: Bool = false
    @State private var scrubberDragValue: Double = 0


    // Transcription
    @ObservedObject private var transcriptionService = TranscriptionService.shared
    /// Shared in-flight tracker used by the Bibliotek pill. Observing
    /// here means the player reflects whichever surface kicked off the
    /// run — single source of truth, no double-press from two
    /// locations.
    @ObservedObject private var transcriptionRunner = TranscriptionRunner.shared
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var transcriptionResult: TranscriptionResult?
    @State private var transcriptionError: TranscriptionError?
    @State private var isTranscribing = false
    @AppStorage("transcription.defaultModel")    private var defaultModelRaw = TranscriptionModel.large.rawValue
    @AppStorage("transcription.defaultSpeakers") private var defaultSpeakers = 2
    @AppStorage("transcription.verbatim")        private var verbatim = false
    @AppStorage("transcription.language")        private var language = "no"

    // Diarization (step 2)
    @State private var diarizationTask: Task<Void, Never>?
    @State private var isDiarizing = false
    @State private var diarizationError: String? = nil

    @State private var showSettings = false
    @State private var transcriptMeta: TranscriptMeta? = nil

    private var isCurrentFile: Bool {
        audioPlayer.currentPlayingURL == recording.audioURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero section
                VStack(spacing: 32) {
                    Spacer().frame(height: 60)

                    ZStack {
                        Circle()
                            .fill(.blue.opacity(0.1))
                            .frame(width: 160, height: 160)
                        Image(systemName: "waveform")
                            .font(.system(size: 64, weight: .light))
                            .symbolEffect(.variableColor.iterative.reversing, isActive: isCurrentFile && audioPlayer.isPlaying)
                            .foregroundStyle(isCurrentFile && audioPlayer.isPlaying ? .blue : .secondary)
                    }

                    // Play/pause button
                    Button {
                        let url = recording.audioURL
                        if isCurrentFile {
                            audioPlayer.togglePlayPause()
                        } else {
                            audioPlayer.play(url: url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                            Text(isCurrentFile && audioPlayer.isPlaying ? "Pause" : "Spill av")
                                .font(.title3.weight(.semibold))
                        }
                        .frame(minWidth: 200)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if isCurrentFile {
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                Button {
                                    audioPlayer.restart()
                                } label: {
                                    Image(systemName: "backward.end.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Restart")

                                Slider(
                                    value: isDraggingScrubber
                                        ? $scrubberDragValue
                                        : Binding(
                                            get: { audioPlayer.playbackProgress },
                                            set: { _ in }
                                        ),
                                    in: 0...1,
                                    onEditingChanged: { dragging in
                                        if dragging {
                                            isDraggingScrubber = true
                                            scrubberDragValue = audioPlayer.playbackProgress
                                        } else {
                                            audioPlayer.seek(to: scrubberDragValue)
                                            isDraggingScrubber = false
                                        }
                                    }
                                )
                                .accentColor(Color(red: 200/255, green: 16/255, blue: 46/255))
                            }
                            .padding(.horizontal, 40)

                            HStack {
                                Text(formattedTime(
                                    (isDraggingScrubber ? scrubberDragValue : audioPlayer.playbackProgress)
                                    * audioPlayer.duration
                                ))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                Spacer()
                                Text(formattedTime(audioPlayer.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 40)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer().frame(height: 40)
                }
                .frame(maxWidth: .infinity)
                .padding()

                Divider().padding(.horizontal)

                Form {
                    transcriptionSection
                    diarizationSection

                    avidentifiseringBekreftSection
                    teamsUploadSection

                    Section("Fil informasjon") {
                        LabeledContent("Filnavn") {
                            Text(recording.filename)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        LabeledContent("Dato") { Text(recording.formattedDate) }
                        LabeledContent("Varighet") {
                            Text(recording.formattedDuration).font(.body.monospacedDigit())
                        }
                        LabeledContent("Størrelse") { Text(recording.formattedSize) }
                    }

                    if let meta = transcriptMeta, meta.status == .done {
                        Section("Transkripsjonsdetaljer") {
                            if let engine = meta.engine {
                                LabeledContent("Modell") { Text(transcriptionModelDisplayName(engine)) }
                            }
                            if let beams = meta.numBeams {
                                LabeledContent("Nøyaktighet") { Text(beamsDisplayName(beams)) }
                            }
                            if let secs = meta.processingTimeSeconds {
                                LabeledContent("Transkripsjonstid") { Text(formattedProcessingTime(secs)) }
                            }
                            if let completedAt = meta.completedAt {
                                LabeledContent("Ferdigstilt") {
                                    Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(recording.filename)
        .navigationSubtitle("\(recording.formattedDate) · \(recording.formattedDuration)")
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Innstillinger")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Lukk") { showSettings = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        TranscriptionSettingsView()
                        Divider()
                            .padding(.horizontal, AppSpacing.lg)
                        LLMSettingsSection()
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 500)
        }
        .onAppear {
            restoreTranscriptionStateIfNeeded()
            transcriptMeta = loadMeta()?.transcript
        }
        .onChange(of: transcriptionRunner.inFlight) { _, newValue in
            // When the runner removes this recording (job finished or
            // was cancelled), refresh the local cache so the player
            // flips from "Transkriberer …" to the completed state.
            if !newValue.contains(recording.id) {
                transcriptionResult = nil
                restoreTranscriptionStateIfNeeded()
                transcriptMeta = loadMeta()?.transcript
            }
        }
        .onDisappear {
            // Cancel only local-state tasks (legacy path). Never cancel the
            // shared TranscriptionRunner — jobs must survive navigation.
            transcriptionTask?.cancel()
            diarizationTask?.cancel()
        }
    }

    // MARK: - Transcription state restoration

    private func loadMeta() -> RecordingMeta? {
        try? RecordingStore.shared.load(id: recording.id)
    }

    private func transcriptionModelDisplayName(_ engine: String) -> String {
        switch engine {
        case "tiny":   return "NB-Whisper Tiny"
        case "base":   return "NB-Whisper Base"
        case "small":  return "NB-Whisper Small"
        case "medium": return "NB-Whisper Medium"
        case "large":  return "NB-Whisper Large"
        default:       return engine
        }
    }

    private func beamsDisplayName(_ beams: Int) -> String {
        switch beams {
        case 1: return "Raskest (1)"
        case 2: return "Rask (2)"
        case 3: return "Middels (3)"
        case 4: return "Treg (4)"
        case 5: return "Svært treg (5)"
        default: return "\(beams)"
        }
    }

    private func formattedProcessingTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) sek" }
        let m = s / 60
        let rem = s % 60
        return rem == 0 ? "\(m) min" : "\(m) min \(rem) sek"
    }

    @ViewBuilder private var avidentifiseringBekreftSection: some View {
        let meta = loadMeta() ?? RecordingMeta(
            schemaVersion: RecordingMeta.currentSchemaVersion,
            id: recording.id,
            createdAt: recording.date,
            displayName: recording.filename,
            durationSeconds: recording.duration,
            audio: AudioMeta(filename: recording.filename, status: .done),
            transcript: TranscriptMeta(status: (TranscriptionCache.shared.hasResult(for: recording.path) || FileManager.default.fileExists(atPath: StorageLayout.transcriptURL(id: recording.id).path)) ? .done : .pending),
            anonymization: AnonymizationMeta(),
            upload: UploadState()
        )
        if meta.transcript.status == .done {
            Section("Avidentifisering") {
                AvidentifiseringBekreftSection(
                    recording: meta,
                    onMetaChanged: { updated in
                        try? RecordingStore.shared.updateMeta(id: updated.id) { m in
                            m.anonymization.researcherConfirmedAt = updated.anonymization.researcherConfirmedAt
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder private var teamsUploadSection: some View {
        let meta = loadMeta() ?? RecordingMeta(
            schemaVersion: RecordingMeta.currentSchemaVersion,
            id: recording.id,
            createdAt: recording.date,
            displayName: recording.filename,
            durationSeconds: recording.duration,
            audio: AudioMeta(filename: recording.filename, status: .done),
            transcript: TranscriptMeta(status: (TranscriptionCache.shared.hasResult(for: recording.path) || FileManager.default.fileExists(atPath: StorageLayout.transcriptURL(id: recording.id).path)) ? .done : .pending),
            anonymization: AnonymizationMeta(),
            upload: UploadState()
        )
        Section("Opplasting til Teams") {
            TeamsUploadSection(recording: meta)
        }
    }

    /// Restores a cached TranscriptionResult for this file (in-memory cache first,
    /// then JSON on disk, then transcript.txt in the recording's UUID folder).
    private func restoreTranscriptionStateIfNeeded() {
        guard transcriptionResult == nil, !isTranscribing else { return }

        // 1. In-memory cache hit (same app session)
        if let cached = TranscriptionCache.shared.result(for: recording.path) {
            transcriptionResult = cached
            return
        }

        // 2. JSON transcript fallback: check Application Support/AudioRecordingManager/transcripts/<uuid>.json
        //    This preserves speaker diarization labels across app restarts.
        //    Uses recording.id (stable UUID) instead of the audio filename stem
        //    (which is always "audio" in the Phase 0 layout and would collide).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jsonURL = support.appendingPathComponent("AudioRecordingManager/transcripts/\(recording.id.uuidString).json")
        if FileManager.default.fileExists(atPath: jsonURL.path),
           let jsonData = try? Data(contentsOf: jsonURL) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let result = try? decoder.decode(TranscriptionResult.self, from: jsonData) {
                transcriptionResult = result
                TranscriptionCache.shared.store(result, for: recording.path)
                return
            }
        }

        // 3. Disk fallback: check transcript.txt in the recording's UUID folder
        let txtURL = StorageLayout.transcriptURL(id: recording.id)

        if FileManager.default.fileExists(atPath: txtURL.path),
           let text = try? String(contentsOf: txtURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Build a minimal TranscriptionResult from the plain-text so the UI
            // can show the "Ferdig" state and "Vis transkripsjon" button.
            let segment = TranscriptionSegment(
                id: 0,
                start: 0,
                end: 0,
                text: text,
                speaker: "SPEAKER_00",
                confidence: 1.0,
                words: []
            )
            let meta = TranscriptionResultMetadata(
                inputFile: recording.path,
                processingTimeSeconds: 0,
                modelVariant: "ukjent",
                computeType: "ukjent",
                device: "ukjent",
                diarizationRun: nil
            )
            let result = TranscriptionResult(
                version: "1.0",
                model: "ukjent",
                language: "no",
                durationSeconds: 0,
                numSpeakers: 1,
                segments: [segment],
                metadata: meta
            )
            transcriptionResult = result
            // Also populate the cache so future navigations skip disk I/O
            TranscriptionCache.shared.store(result, for: recording.path)
        }
    }

    // MARK: - Transcription section

    @ViewBuilder
    private var transcriptionSection: some View {
        Section("Transkripsjon") {
            let runnerInFlight = transcriptionRunner.inFlight.contains(recording.id)

            if runnerInFlight {
                TranscriptionProgressView(
                    stageName: transcriptionService.stage.displayName,
                    startTime: transcriptionRunner.startTimes[recording.id],
                    audioDuration: transcriptionRunner.audioDurations[recording.id],
                    model: defaultModelRaw,
                    numBeams: { let v = UserDefaults.standard.integer(forKey: "transcription.numBeams"); return v == 0 ? 3 : v }()
                )
                Button("Avbryt", role: .destructive) {
                    transcriptionRunner.cancel(recordingId: recording.id)
                }
            } else if isTranscribing {
                // Local-state transcription path (back-compat; new clicks go through runner).
                TranscriptionProgressView(
                    stageName: transcriptionService.stage.displayName,
                    startTime: nil,
                    audioDuration: nil
                )
                Button("Avbryt", role: .destructive, action: cancelTranscription)
            } else if let result = transcriptionResult {
                // Completed
                Label {
                    Text("Ferdig — \(result.segments.count) segmenter, \(result.numSpeakers) taler\(result.numSpeakers == 1 ? "" : "e")")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    onNavigateToTranscript?(recording.id)
                } label: {
                    Label("Åpne i transkripsjonseditoren", systemImage: "doc.text")
                }
                Button {
                    transcriptionRunner.start(recordingId: recording.id, audioDuration: recording.duration)
                } label: {
                    Label("Transkriber på nytt", systemImage: "arrow.counterclockwise")
                }
                .disabled(transcriptionService.isBusy)
            } else if let error = transcriptionError {
                // Failed
                Label {
                    Text("Feil: \(error.errorDescription ?? "Ukjent feil")")
                        .foregroundStyle(.red)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Button("Prøv igjen") {
                    transcriptionRunner.start(recordingId: recording.id, audioDuration: recording.duration)
                }
            } else {
                // Not started
                if transcriptionService.isInstalled {
                    Button {
                        transcriptionRunner.start(recordingId: recording.id, audioDuration: recording.duration)
                    } label: {
                        Label("Transkriber med NB-Whisper", systemImage: "waveform.and.mic")
                    }
                    .disabled(transcriptionService.isBusy)
                    let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .medium
                    if transcriptionService.isBusy {
                        Text("En transkripsjon kjører allerede – vennligst vent.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Modell: \(model.displayName) · \(defaultSpeakers) taler\(defaultSpeakers == 1 ? "" : "e")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if transcriptionService.isSettingUp {
                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                        Text("Setter opp transkripsjon…")
                    }
                    let stageDesc = transcriptionService.setupStageDescription
                    Text(stageDesc.isEmpty
                         ? "Første gangs installasjon tar 5–15 min (torch ~2 GB)."
                         : stageDesc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let err = transcriptionService.setupError {
                    Label("Oppsett feilet", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Prøv igjen") {
                        Task { await TranscriptionService.shared.setupIfNeeded() }
                    }
                } else {
                    // setupIfNeeded() har ikke kjørt ennå (f.eks. første gang etter cold start)
                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                        Text("Setter opp transkripsjon…")
                    }
                    Text("Starter oppsett. Vennligst vent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onAppear {
                            Task { await TranscriptionService.shared.setupIfNeeded() }
                        }
                }
            }
        }
    }

    // MARK: - Diarization section

    @ViewBuilder
    private var diarizationSection: some View {
        Section("Talerutskilling") {
            if isDiarizing {
                HStack(spacing: 10) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                    Text(transcriptionService.stage == .diarizing
                         ? "Identifiserer talere..."
                         : "Forbereder...")
                }
                if transcriptionService.diarizationProgress > 0 {
                    ProgressView(value: transcriptionService.diarizationProgress)
                        .animation(.easeInOut(duration: 0.4), value: transcriptionService.diarizationProgress)
                }
                Button("Avbryt", role: .destructive) {
                    diarizationTask?.cancel()
                    TranscriptionService.shared.cancel()
                    isDiarizing = false
                }
            } else if let result = transcriptionResult, result.metadata.diarizationRun == true {
                // Completed
                Label {
                    Text("Talere identifisert")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    startDiarization()
                } label: {
                    Label("Kjør på nytt", systemImage: "arrow.counterclockwise")
                }
            } else if let error = diarizationError {
                Label {
                    Text(error).foregroundStyle(.red)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Button("Prøv igjen", action: startDiarization)
            } else {
                // Not started
                if transcriptionResult != nil {
                    Button {
                        startDiarization()
                    } label: {
                        Label("Identifiser talere", systemImage: "person.2.fill")
                    }
                    .disabled(isTranscribing)
                    Text("FluidAudio (lokalt, Apple Neural Engine) · \(defaultSpeakers) talere")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Transkriber lydfilen først")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Actions

    private func startTranscription() {
        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .medium
        let audioURL = recording.audioURL

        transcriptionTask?.cancel()
        transcriptionError = nil
        isTranscribing = true

        // A new transcription invalidates any previous anonymization.
        clearAnonymizationData(for: recording.id)

        transcriptionTask = Task { @MainActor in
            do {
                let result = try await TranscriptionService.shared.transcribe(
                    audioFile: audioURL,
                    speakers: defaultSpeakers,
                    model: model,
                    verbatim: verbatim,
                    language: language
                )
                guard !Task.isCancelled else { return }
                transcriptionResult = result
                isTranscribing = false

                // Store in the in-memory cache so the result survives file navigation
                TranscriptionCache.shared.store(result, for: recording.path)
                // Save full TranscriptionResult JSON to disk (preserves speaker labels across restarts)
                TranscriptionService.shared.saveTranscriptJSONPublic(result, recordingId: recording.id)
                ProcessingStateCache.shared.setStep(.transcription, status: .completed, for: recording.path)

                // Persist plain-text transcript into the recording's UUID folder
                let plainText = result.segments
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n\n")

                let transcriptURL = StorageLayout.transcriptURL(id: recording.id)
                try? plainText.write(to: transcriptURL, atomically: true, encoding: .utf8)
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .done
                    meta.transcript.completedAt = Date()
                    meta.transcript.engine = model.rawValue
                }

                AuditLogger.shared.log(.transcriptCompleted, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "engine": .string(model.rawValue),
                    "segmentCount": .int(result.segments.count),
                ])

                NotificationCenter.default.post(
                    name: .armTranscriptionDidComplete,
                    object: recording.id
                )
            } catch let error as TranscriptionError {
                guard !Task.isCancelled else { return }
                transcriptionError = error
                isTranscribing = false
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .failed
                }
                AuditLogger.shared.log(.transcriptFailed, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "error": .string(error.errorDescription ?? "unknown"),
                ])
            } catch {
                guard !Task.isCancelled else { return }
                transcriptionError = .processFailed(error.localizedDescription)
                isTranscribing = false
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .failed
                }
                AuditLogger.shared.log(.transcriptFailed, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            }
        }
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        TranscriptionService.shared.cancel()
        isTranscribing = false
    }

    private func clearAnonymizationData(for id: UUID) {
        _ = try? RecordingStore.shared.updateMeta(id: id) { meta in
            meta.anonymization = AnonymizationMeta()
        }
        let fm = FileManager.default
        try? fm.removeItem(at: StorageLayout.anonymizedTranscriptURL(id: id))
        try? fm.removeItem(at: StorageLayout.anonymizationResultURL(id: id))
        AuditLogger.shared.log(.anonymizationClearedOnRetranscription, payload: [
            "recordingId": .string(id.uuidString),
            "reason": .string("re-transcription"),
        ])
    }

    private func startDiarization() {
        guard let result = transcriptionResult else { return }
        isDiarizing = true
        diarizationError = nil
        diarizationTask = Task {
            do {
                let updated = try await TranscriptionService.shared.diarize(
                    audioFile: recording.audioURL,
                    existingResult: result,
                    speakers: defaultSpeakers
                )
                await MainActor.run {
                    transcriptionResult = updated
                    isDiarizing = false
                }
            } catch {
                await MainActor.run {
                    diarizationError = error.localizedDescription
                    isDiarizing = false
                }
            }
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
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
                .fill(Color(nsColor: NSColor.controlColor))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(nsColor: NSColor.labelColor))
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
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @State private var showDeleteConfirm = false
    @State private var isHovering = false

    /// True when this recording has a transcription result — either in the session cache
    /// or as a saved transcript.txt in the recording's UUID folder.
    private var hasTranscription: Bool {
        if TranscriptionCache.shared.hasResult(for: recording.path) { return true }
        let txtURL = StorageLayout.transcriptURL(id: recording.id)
        return FileManager.default.fileExists(atPath: txtURL.path)
    }

    private var hasDiarization: Bool {
        ProcessingStateCache.shared.state(for: recording.path).diarization.status == .completed
    }

    private var hasAnalysis: Bool {
        ProcessingStateCache.shared.state(for: recording.path).analysis.status == .completed
    }

    private var expiryState: ExpiryWarningState {
        guard let meta = loadMeta() else { return .none }
        return RecordingExpiryManager.shared.warningState(for: meta)
    }

    private var isAudioUploaded: Bool {
        guard let meta = loadMeta() else { return false }
        return meta.upload.audio.status == .uploaded
    }

    private func loadMeta() -> RecordingMeta? {
        do { return try RecordingStore.shared.load(id: recording.id) }
        catch { return nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "waveform" : "waveform.circle")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.filename)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(contentColor)

                    HStack(spacing: 4) {
                        Text(recording.formattedDate)
                        Text("·")
                        Text(recording.formattedDuration)
                    }
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(subtleColor)
                }

                Spacer()

                HStack(spacing: 4) {
                    if hasTranscription {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(Color(red: 200/255, green: 16/255, blue: 46/255).opacity(0.8))
                            .help("Transkribert")
                    }
                    if hasDiarization {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue.opacity(0.7))
                            .help("Talere identifisert")
                    }
                    if hasAnalysis {
                        Image(systemName: "brain.head.profile")
                            .font(.caption2)
                            .foregroundStyle(.purple.opacity(0.7))
                            .help("Analysert")
                    }
                }

                Text(recording.formattedSize)
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(subtleColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }

            if expiryState != .none {
                ExpiryWarningBanner(warningState: expiryState, isUploaded: isAudioUploaded)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider().background(Color.gray.opacity(0.25))
        }
        .onHover { isHovering = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active: DispatchQueue.main.async { NSCursor.pointingHand.set() }
            case .ended: DispatchQueue.main.async { NSCursor.arrow.set() }
            }
        }
        .alert("Slett opptak?", isPresented: $showDeleteConfirm) {
            Button("Avbryt", role: .cancel) {}
            Button("Slett", role: .destructive) {
                if isPlaying { audioPlayer.stop() }
                recordingsManager.deleteRecording(recording)
            }
        } message: {
            Text("Er du sikker på at du vil slette \(recording.filename)?")
        }
        .contextMenu {
            Button(action: {
                let url = recording.audioURL
                if isPlaying {
                    audioPlayer.togglePlayPause()
                } else {
                    audioPlayer.play(url: url)
                }
            }) {
                Label(isPlaying ? "Pause" : "Spill av", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }

            Divider()

            Divider()

            Button(role: .destructive, action: { showDeleteConfirm = true }) {
                Label("Slett", systemImage: "trash")
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return AppColors.accent }
        if isHovering { return Color.gray.opacity(0.08) }
        return Color.clear
    }

    private var contentColor: Color { isSelected ? .white : .primary }
    private var subtleColor: Color { isSelected ? .white.opacity(0.75) : .secondary }
    private var iconColor: Color {
        if isSelected { return .white }
        return isPlaying ? AppColors.accent : AppColors.accent.opacity(0.7)
    }
}

// MARK: - Recording Name Dialog
struct RecordingNameDialog: View {
    @Binding var recordingName: String
    let duration: TimeInterval
    let onSave: () -> Void
    let onDiscard: () -> Void
    @FocusState private var isTextFieldFocused: Bool
    @State private var showNameWarningAlert = false

    private var nameDetected: Bool {
        NameDetector.shared.containsName(in: recordingName)
    }

    var body: some View {
        VStack(spacing: 22) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.accent)

                Text("Gi opptaket et navn")
                    .font(.system(size: 18, weight: .semibold))

                Text("Varighet: \(formatDuration(duration))")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // Filename input
            VStack(alignment: .leading, spacing: 6) {
                Text("Navn på opptak")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("f.eks. intervju-deltaker-01", text: $recordingName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($isTextFieldFocused)
                    .onSubmit { trySave() }

                if nameDetected {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.warning)
                            .font(.system(size: 11))
                        Text("Vi kan ha oppdaget et personnavn i filnavnet.")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.warning)
                    }
                } else {
                    Text("Tidsstempel legges til automatisk")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }

            // Preview
            if !recordingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 6) {
                    Text("Forhåndsvisning:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(recordingName.trimmingCharacters(in: .whitespacesAndNewlines))_\(previewTimestamp()).m4a")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onDiscard) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                        Text("Forkast")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: trySave) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                        Text("Lagre")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 400)
        .onAppear {
            isTextFieldFocused = true
        }
        .alert("Mulig personopplysning i filnavn", isPresented: $showNameWarningAlert) {
            Button("Fortsett", role: .none) { onSave() }
            Button("Endre filnavn", role: .cancel) {}
        } message: {
            Text("Vi tror filnavnet kan inneholde et personnavn. Vil du fortsette, eller endre filnavnet?")
        }
    }

    private func trySave() {
        if nameDetected {
            showNameWarningAlert = true
        } else {
            onSave()
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func previewTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Silence Warning Dialog
struct SilenceWarningDialog: View {
    let onContinue: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.warning)
                Text("Ingen lyd registrert")
                    .font(.system(size: 18, weight: .semibold))
                Text("Vi har ikke registrert stemmer eller lyd på en stund. Vil du pause eller stoppe opptaket?")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                Button(action: onContinue) {
                    Text("Fortsett opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(action: onPause) {
                    Text("Pause opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button(action: onStop) {
                    Text("Stopp opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(28)
        .frame(width: 400)
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
    @State private var recordingName = ""  // User-entered filename
    @State private var glowRadius: CGFloat = 10
    @State private var glowOpacity: Double = 0.2

    var body: some View {
        // Main recording area (sidebar is now global in MainView)
        mainRecordingView
            .sheet(isPresented: $recorder.showNamingDialog) {
                RecordingNameDialog(
                    recordingName: $recordingName,
                    duration: recorder.recordingDuration,
                    onSave: {
                        recorder.saveRecordingWithName(recordingName)
                        recordingName = ""  // Reset for next recording
                    },
                    onDiscard: {
                        recorder.cancelPendingRecording()
                        recordingName = ""
                    }
                )
            }
            .sheet(isPresented: $recorder.showSilenceWarning) {
                SilenceWarningDialog(
                    onContinue: {
                        recorder.dismissSilenceWarning()
                    },
                    onPause: {
                        recorder.showSilenceWarning = false
                        recorder.pauseRecording()
                    },
                    onStop: {
                        recorder.showSilenceWarning = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            recorder.stopRecording()
                        }
                    }
                )
            }
            .onAppear {
                // Audio monitoring only — recordings list stays in sync via
                // RecordingsManager's didChangeNotification subscription.
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

            .onChange(of: recorder.frequencyBands) { _, bands in
                // Update glow state with a smooth animation so it plays through between frames
                // rather than restarting every 23 ms (which caused jitter with inline animation).
                let avg = bands.isEmpty ? 0 : bands.reduce(0, +) / Float(bands.count)
                let amplified = min(Double(avg) * 3.0, 1.0)
                withAnimation(.easeInOut(duration: 0.2)) {
                    glowRadius = CGFloat(amplified) * 30 + 10   // 10–40 pt
                    glowOpacity = amplified * 0.8 + 0.2          // 0.2–1.0
                }
                // Auto-verify when audio is detected
                if !microphoneVerified, avg > 0.15 {
                    microphoneVerified = true
                    verificationTimer?.invalidate()
                }
            }
    }

    var mainRecordingView: some View {
        VStack(spacing: 0) {
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
                                .foregroundStyle(.green)
                            Text("Recording Saved")
                                .font(.system(size: 24, weight: .light))
                            if let filename = recorder.lastSavedFile {
                                Text(filename)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(48)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(2)
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        // Microphone Icon with pulsing glow
                        VStack(spacing: 24) {
                            Image(
                                systemName: recorder.isRecording && !recorder.isPaused
                                    ? "mic.fill" : "mic"
                            )
                            .font(.system(size: 72, weight: .ultraLight))
                            .foregroundStyle(
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

                            // Recording Duration
                            if recorder.isRecording || recorder.recordingDuration > 0 {
                                Text(formatDuration(recorder.recordingDuration))
                                    .font(.system(size: 64, weight: .thin, design: .default))
                                    .foregroundStyle(recorder.isPaused ? .orange : .primary)
                                    .tracking(2)
                                    .monospacedDigit()
                            }

                            // Status Text - minimal
                            if recorder.isPaused {
                                Text("Paused")
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundStyle(.orange)
                                    .textCase(.uppercase)
                                    .tracking(2)
                            } else if recorder.isRecording {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 6, height: 6)
                                    Text("Recording")
                                        .font(.system(size: 14, weight: .light))
                                        .foregroundStyle(.red)
                                        .textCase(.uppercase)
                                        .tracking(2)
                                }
                            }
                        }
                    }

                    Spacer()

                    // Scrolling Waveform Timeline - Only visible when recording
                    if recorder.isRecording {
                        ScrollingWaveformView(
                            waveformHistory: recorder.waveformHistory,
                            isRecording: recorder.isRecording
                        )
                        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }

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
                                            .foregroundStyle(.red.opacity(0.8))
                                            .frame(width: 56, height: 56)
                                            .background(Color.red.opacity(0.08))
                                            .cornerRadius(2)
                                        Text("Delete")
                                            .font(.system(size: 11, weight: .light))
                                            .foregroundStyle(.red.opacity(0.8))
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
                                            .foregroundStyle(.orange.opacity(0.8))
                                            .frame(width: 56, height: 56)
                                            .background(Color.orange.opacity(0.08))
                                            .cornerRadius(2)
                                        Text(recorder.isPaused ? "Resume" : "Pause")
                                            .font(.system(size: 11, weight: .light))
                                            .foregroundStyle(.orange.opacity(0.8))
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
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let milliseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }

}

// MARK: - Recording Player Panel (right panel for Lydopptak tab)

struct RecordingPlayerPanel: View {
    let recording: RecordingItem
    @ObservedObject var audioPlayer: AudioPlayer

    private var isCurrentFile: Bool {
        audioPlayer.currentPlayingURL == recording.audioURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Spacer().frame(height: 20)

                // Icon
                Image(systemName: "waveform")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(isCurrentFile && audioPlayer.isPlaying ? AppColors.accent : .secondary.opacity(0.5))
                    .animation(.easeInOut(duration: 0.2), value: audioPlayer.isPlaying)

                // Play/pause button
                Button(action: {
                    let url = recording.audioURL
                    if isCurrentFile {
                        audioPlayer.togglePlayPause()
                    } else {
                        audioPlayer.play(url: url)
                    }
                }) {
                    Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72, weight: .thin))
                        .foregroundStyle(AppColors.accent)
                }
                .buttonStyle(.plain)

                // Progress bar (only when this recording is active)
                if isCurrentFile {
                    VStack(spacing: 6) {
                        ProgressView(value: audioPlayer.playbackProgress)
                            .tint(AppColors.accent)
                            .padding(.horizontal, 60)

                        HStack {
                            Text(formattedTime(audioPlayer.playbackProgress * audioPlayer.duration))
                            Spacer()
                            Text(recording.formattedDuration)
                        }
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 60)
                    }
                    .transition(.opacity)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(recording.filename)
        .navigationSubtitle("\(recording.formattedDate) · \(recording.formattedDuration) · \(recording.formattedSize)")
        .animation(.easeInOut(duration: 0.2), value: isCurrentFile)
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - About View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Om Clio")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Version
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Versjon \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Button(action: {
                            if let url = URL(string: "https://github.com/Fr35ch/clio/releases") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12))
                                Text("Se endringslogg")
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(AppColors.accent)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }

                    Divider()

                    // Purpose
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Formål")
                            .font(.headline)
                        Text(
                            "Clio er et verktøy for Nav-innsiktsmedarbeidere som gjennomfører intervjuer. Det støtter opptak, lokal transkribering, taleutskilling, avidentifisering, analyse og opplasting til Teams – alt uten å sende data til eksterne tjenester."
                        )
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Key Features
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Funksjoner")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            FeatureRow(
                                icon: "mic.fill",
                                text: "Lydopptak")
                            FeatureRow(
                                icon: "waveform",
                                text: "Lokal transkribering med NB-Whisper")
                            FeatureRow(
                                icon: "person.2.wave.2",
                                text: "Taleutskilling – identifisering av hvem som snakker")
                            FeatureRow(
                                icon: "person.badge.minus",
                                text: "Avidentifisering av personopplysninger")
                            FeatureRow(
                                icon: "text.magnifyingglass",
                                text: "Analyse av transkripsjonen")
                            FeatureRow(
                                icon: "arrow.up.doc",
                                text: "Opplasting til Teams etter bekreftet avidentifisering")
                        }
                    }

                    Divider()

                    // Quick Start
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Slik kommer du i gang")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Ta opp")
                                .fontWeight(.semibold)
                            Text("   Klikk «Ta opp» for å starte et nytt intervjuopptak.")
                                .foregroundStyle(.secondary)

                            Text("2. Transkriber")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Velg opptaket og klikk «Transkriber» for lokal tale-til-tekst.")
                                .foregroundStyle(.secondary)

                            Text("3. Avidentifiser")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Rediger transkripsjonen og bekreft avidentifisering.")
                                .foregroundStyle(.secondary)

                            Text("4. Analyser")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Bruk analysevertøyet til å trekke ut innsikt fra transkripsjonen.")
                                .foregroundStyle(.secondary)

                            Text("5. Last opp til Teams")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Opplasting blir tilgjengelig etter bekreftet avidentifisering.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.body)
                    }

                    Divider()

                    // Technologies
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Teknologi")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Swift & SwiftUI (macOS 14+)")
                            Text("• AVFoundation – lydopptak")
                            Text("• NB-Whisper via no-transcribe – norsk tale-til-tekst")
                            Text("• no-anonymizer – BERT-basert avidentifisering")
                            Text("• FluidAudio – lokal talegjenkjenning (diarisering)")
                            Text("• Microsoft Graph API – opplasting til Teams")
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Footer
                    Text("© 2026 NAV. Med enerett.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                }
                .padding()
            }
        }
        .frame(width: 600, height: 700)
    }
}

// Helper view for feature rows
struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(AppColors.accent)
                .frame(width: 20)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
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
                    .padding(.vertical, AppSpacing.sm)

                SidebarMenuItem(
                    icon: "info.circle",
                    title: "Om Clio",
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
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Clio – Audio Recording Manager")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(width: 315, alignment: .leading)
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
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill(.ultraThinMaterial)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}


struct MainView: View {
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var recordingsManager = RecordingsManager.shared
    @StateObject private var audioPlayer = AudioPlayer.shared

    @State private var selectedTab: AppTab = .record
    @State private var selectedRecording: RecordingItem? = nil
    @State private var selectedAnalysisId: UUID? = nil
    @State private var showAbout = false
    @State private var showLogViewer = false
    @State private var showDesignShowcase = false
    @State private var showSettings = false

    var body: some View {
        // NavigationSplitView wrapper is REQUIRED for SwiftUI's unified
        // chrome to extend content to the window's outer rounded frame.
        // See `Design/WindowChrome.swift` — bare HStack at root breaks
        // the corner-radius pipeline. The actual nav lives inside detail.
        NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
            EmptyView()
        } detail: {
            HStack(spacing: 0) {
                NavPanel(
                    selectedTab: $selectedTab,
                    showAbout: $showAbout
                )
                .frame(width: 64)

                Divider()

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 700)
        .sheet(isPresented: $showAbout) {
            AboutView().presentationDetents([.large])
        }
        .sheet(isPresented: $showLogViewer) {
            PasswordGateView(isPresented: $showLogViewer)
        }
        .sheet(isPresented: $showDesignShowcase) {
            DesignShowcaseView(isPresented: $showDesignShowcase)
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Innstillinger")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Lukk") { showSettings = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        TranscriptionSettingsView()
                        Divider()
                            .padding(.horizontal, AppSpacing.lg)
                        LLMSettingsSection()
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 500)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowLogViewer"))) { _ in
            showLogViewer = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowDesignShowcase"))) { _ in
            showDesignShowcase = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowSettings"))) { _ in
            showSettings = true
        }
        .onChange(of: selectedTab) { _, _ in autoSelectFirst() }
        .onChange(of: recordingsManager.recordings) { _, _ in
            if selectedTab == .recordings { autoSelectFirst() }
        }
        .onAppear { /* RecordingsManager loads on init and stays in sync via notifications */ }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .record:
            RecordingView(recorder: audioRecorder, isShowing: .constant(true))
        case .recordings:
            BibliotekScreen(
                recordingsManager: recordingsManager,
                audioPlayer: audioPlayer,
                selectedRecording: $selectedRecording
            )
        case .analyse:
            AnalyseScreen(selectedAnalysisId: $selectedAnalysisId)
        }
    }

    private func autoSelectFirst() {
        switch selectedTab {
        case .record:
            break
        case .recordings:
            if selectedRecording == nil {
                selectedRecording = recordingsManager.recordings.first
            }
        case .analyse:
            if selectedAnalysisId == nil {
                selectedAnalysisId = AnalysisStore.shared.loadAll().first?.id
            }
        }
    }
}

private let listColumnWidth: CGFloat = 320

struct BibliotekScreen: View {
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var audioPlayer: AudioPlayer
    @Binding var selectedRecording: RecordingItem?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                BibliotekView(
                    recordingsManager: recordingsManager,
                    audioPlayer: audioPlayer,
                    selectedRecording: $selectedRecording,
                    isCompact: true
                )
                .frame(width: max(560, geo.size.width * 0.62))

                Divider()

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let recording = selectedRecording {
            RecordingPlayerNative(
                recording: recording,
                audioPlayer: audioPlayer,
                onNavigateToTranscript: { id in
                    openWindow(id: "transcript-editor", value: id)
                }
            )
            .id(recording.path)
        } else {
            ContentUnavailableView(
                "Ingen opptak ennå",
                systemImage: "waveform",
                description: Text("Bruk «Ta opp lyd» for å starte ditt første opptak.")
            )
        }
    }
}

struct AnalyseScreen: View {
    @Binding var selectedAnalysisId: UUID?

    var body: some View {
        HStack(spacing: 0) {
            AnalysisListColumn(selectedAnalysisId: $selectedAnalysisId)
                .frame(width: listColumnWidth)

            Divider()

            AnalysisDetailColumn(selectedAnalysisId: $selectedAnalysisId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

ClioApp.main()
