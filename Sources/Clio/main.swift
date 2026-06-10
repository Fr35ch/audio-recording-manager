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
                Button(AppCopy.Menu.logViewer) {
                    NotificationCenter.default.post(name: .init("ClioShowLogViewer"), object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button(AppCopy.Menu.designSystem) {
                    NotificationCenter.default.post(name: .init("ClioShowDesignShowcase"), object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(AppCopy.Menu.settingsWithEllipsis) {
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

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        print("🖥️ Clio Desktop v\(version) (build \(build))")

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
            "beta.enabled":                  false,
        ])

        // Ensure storage directories exist
        try? StorageLayout.ensureDirectoriesExist()

        // Start the Bonjour confirmation server so iOS devices can query
        // whether a transferred file has been received and indexed.
        BonjourConfirmationServer.shared.start()

        // Watch ~/Downloads for recordings AirDropped from Clio Recorder iOS
        // and import them into the library automatically.
        AirDropImportWatcher.shared.start()

        // Advertise as a Clio receiver for Clio Recorder iOS direct transfer.
        NearbyTransferAdvertiser.shared.start()

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
        BonjourConfirmationServer.shared.stop()
        AirDropImportWatcher.shared.stop()
        NearbyTransferAdvertiser.shared.stop()
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

// MARK: - View Helpers
// `SplitViewIntrospector`, `CursorHostingView`, `CursorTrackingView`, and the
// `View.cursor()` / `View.introspectSplitView()` extensions have been extracted
// to `Utils/ViewHelpers.swift`.

ClioApp.main()
