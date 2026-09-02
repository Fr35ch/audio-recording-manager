// AppLockManager.swift
// Clio
//
// Mandatory, always-on app lock. Gates the entire UI behind
// `.deviceOwnerAuthentication` (Touch ID with automatic password
// fallback) whenever the app launches, has been idle/backgrounded for
// 5 minutes, or the Mac sleeps / the screen locks.
//
// This app handles highly sensitive NAV interview recordings — see
// AGENTS.md / CLAUDE.md compliance constraints. App lock does not
// replace FileVault or the app's sandbox container isolation (see
// ADR-1014); it closes the "unattended, unlocked session" gap those
// don't cover.

import AppKit
import Foundation
import LocalAuthentication

/// Why the most recent unlock attempt didn't succeed, for
/// `LockScreenView` to render. Kept intentionally coarse — no raw
/// `LAError` leaks into the view layer.
enum UnlockFailureReason: Equatable {
    /// No error to show — either never attempted, or the user cancelled
    /// the system sheet themselves (not worth nagging about).
    case none
    /// Touch ID/password was attempted and didn't match. Safe to retry.
    case authenticationFailed
    /// This Mac has no device password set at all, so
    /// `.deviceOwnerAuthentication` has no possible fallback. Not
    /// recoverable by retrying.
    case noPasscodeSet
    /// Any other/unexpected `LAError`. Safe to retry.
    case other
}

/// Tracks time since the last user interaction with any of Clio's own
/// windows (mouse/keyboard events observed via a local `NSEvent`
/// monitor). Deliberately **not** system-wide: `CGEventSource`-based
/// system-wide idle detection (`secondsSinceLastEventType`) does not
/// work correctly inside the macOS App Sandbox — Apple blocks sandboxed
/// apps from seeing real global input timing, so it silently returns
/// values that don't reflect actual user activity. Since Clio is
/// sandboxed (`ENABLE_APP_SANDBOX = YES`), an earlier version of this
/// file used `CGEventSource` here and locked almost immediately after
/// every unlock, regardless of real activity — this is the fix.
///
/// A local event monitor (as opposed to a *global* one) only observes
/// events already destined for this app's own windows, which needs no
/// special entitlement and works identically inside or outside the
/// sandbox. It's also arguably the more correct signal anyway: what
/// matters for an app-level lock is disuse of Clio itself, not of the
/// Mac in general.
@MainActor
final class LocalActivityTracker {
    static let shared = LocalActivityTracker()

    private var lastInteractionAt = Date()
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .scrollWheel, .keyDown, .keyUp, .flagsChanged,
            ]
        ) { [weak self] event in
            self?.lastInteractionAt = Date()
            return event // pass-through — never consume the event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func secondsSinceLastInteraction() -> TimeInterval {
        Date().timeIntervalSince(lastInteractionAt)
    }
}

@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    /// The app starts locked on every launch — no state is persisted that
    /// could cause it to start unlocked after a force-quit or crash.
    @Published private(set) var isLocked = true
    @Published private(set) var lastFailureReason: UnlockFailureReason = .none

    /// How long the app can sit inactive before it locks itself. Fixed,
    /// not user-configurable — see the app-lock ADR for the reasoning.
    /// `AppLockManager.shared` always uses this default; only tests
    /// inject a shorter interval via `init(idleTimeout:)` so idle-lock
    /// behaviour is verifiable without a real 5-minute wait.
    /// `nonisolated` because it's a plain `Double` constant used as a
    /// default-argument expression, which Swift evaluates outside the
    /// initializer's actor context.
    nonisolated static let defaultIdleTimeout: TimeInterval = 5 * 60

    /// How often the periodic idle checker runs (see
    /// `checkIdleAndLockIfNeeded`). 15s means the lock engages at most
    /// 15s after the real 5-minute mark — a fine trade against polling
    /// more often for no user-visible benefit.
    nonisolated static let defaultIdleCheckInterval: TimeInterval = 15

    /// Returns seconds since the last interaction with Clio's own
    /// windows. Real implementation reads `LocalActivityTracker.shared`;
    /// tests inject a fake so idle behaviour is verifiable without
    /// simulating real mouse/keyboard events. `@MainActor`-typed for the
    /// same reason as `isAppActiveProvider` below — the real
    /// implementation touches main-actor-isolated state.
    typealias IdleTimeProvider = @MainActor () -> TimeInterval

    /// Whether the app is in the middle of something the researcher is
    /// actively relying on right now — an ongoing recording, audio
    /// playback, or transcription. Real implementation checks
    /// `AudioRecorder`, `AudioPlayer`, and `TranscriptionRunner`; tests
    /// inject a fake so this is verifiable without driving real
    /// audio/transcription pipelines. Consulted by *every* idle-based
    /// lock decision (both while active and while backgrounded) — never
    /// lock out from under a live recording or playback session just
    /// because the researcher hasn't touched the keyboard/mouse, or
    /// because they briefly switched apps mid-interview.
    ///
    /// Deliberately **not** consulted by the sleep/screen-lock triggers
    /// or the manual "Lås appen nå" command — those represent the Mac
    /// physically going away or an explicit researcher request, not an
    /// idle heuristic that could misfire, so they always lock regardless.
    typealias AppBusyProvider = @MainActor () -> Bool

    private let authenticator: BiometricAuthenticating
    private let idleTimeout: TimeInterval
    private let idleCheckInterval: TimeInterval
    private let idleTimeProvider: IdleTimeProvider
    /// Real implementation reads `NSApp.isActive`; tests inject a fake
    /// since a headless test process has no real active/frontmost app
    /// state to observe. `@MainActor`-typed (rather than plain
    /// nonisolated) because `NSApp`/`.isActive` are themselves
    /// main-actor-isolated, and this is always invoked from
    /// `checkIdleAndLockIfNeeded`, already on the main actor.
    private let isAppActiveProvider: @MainActor () -> Bool
    private let isAppBusyProvider: AppBusyProvider
    /// Set when the app resigns active, cleared when it becomes active
    /// again. `checkIdleAndLockIfNeeded` (the same periodic timer used
    /// for the foreground case) compares against this instead of the
    /// active-state idle-time provider while backgrounded, so both
    /// "backgrounded" and "foregrounded but idle" funnel through one
    /// mechanism that consistently respects `isAppBusyProvider`. An
    /// earlier version used a one-shot `DispatchWorkItem` here instead —
    /// replaced because a one-shot timer that skips locking once (busy
    /// at fire-time) would then never re-check, so a recording that
    /// finished hours later while still backgrounded would never
    /// actually lock.
    private var resignedActiveAt: Date?
    /// Single periodic checker (see `checkIdleAndLockIfNeeded`), running
    /// continuously from `start()` for the app's whole lifetime.
    private var idleCheckTimer: Timer?
    private var isAuthenticating = false
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    /// `biometryType` needs `canEvaluatePolicy` to have run at least once;
    /// exposed for `LockScreenView` to pick Touch ID vs generic lock copy.
    var biometryType: LABiometryType { authenticator.biometryType }

    init(
        authenticator: BiometricAuthenticating = LAContextAuthenticator(),
        idleTimeout: TimeInterval = AppLockManager.defaultIdleTimeout,
        idleCheckInterval: TimeInterval = AppLockManager.defaultIdleCheckInterval,
        idleTimeProvider: @escaping IdleTimeProvider = {
            LocalActivityTracker.shared.secondsSinceLastInteraction()
        },
        isAppActiveProvider: @escaping @MainActor () -> Bool = { NSApp.isActive },
        isAppBusyProvider: @escaping AppBusyProvider = {
            AudioRecorder.shared.isRecording
                || AudioPlayer.shared.isPlaying
                || !TranscriptionRunner.shared.inFlight.isEmpty
        }
    ) {
        self.authenticator = authenticator
        self.idleTimeout = idleTimeout
        self.idleCheckInterval = idleCheckInterval
        self.idleTimeProvider = idleTimeProvider
        self.isAppActiveProvider = isAppActiveProvider
        self.isAppBusyProvider = isAppBusyProvider
    }

    deinit {
        // NSObjectProtocol tokens don't need MainActor isolation to remove.
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        idleCheckTimer?.invalidate()
    }

    // MARK: - Lifecycle wiring (called once from AppDelegate)

    /// Registers the sleep/screen-lock observers, starts the periodic
    /// idle checker, and attempts the first unlock. Call once, from
    /// `applicationDidFinishLaunching`.
    func start() {
        registerSystemObservers()
        startIdleCheckTimer()
        attemptUnlock()
    }

    /// Call from `AppDelegate.applicationWillResignActive`. Records when
    /// the app went inactive; `checkIdleAndLockIfNeeded` compares against
    /// this once `idleTimeout` has elapsed. Does not lock immediately —
    /// switching to a Finder dialog briefly shouldn't force re-auth.
    func handleWillResignActive() {
        resignedActiveAt = Date()
    }

    /// Call from `AppDelegate.applicationDidBecomeActive`. Clears the
    /// backgrounded-since timestamp if the user returned before the
    /// timeout elapsed.
    func handleDidBecomeActive() {
        resignedActiveAt = nil
    }

    /// Manual "Lås appen nå" menu command.
    func lockNow() {
        lock()
    }

    // MARK: - Periodic idle checking

    /// Polls every `idleCheckInterval` while unlocked, unifying both the
    /// "backgrounded" and "foregrounded but idle" cases into one
    /// mechanism (see `resignedActiveAt`'s doc comment for why a
    /// one-shot backgrounding timer isn't good enough on its own).
    private func startIdleCheckTimer() {
        idleCheckTimer?.invalidate()
        let timer = Timer(timeInterval: idleCheckInterval, repeats: true) { [weak self] _ in
            self?.handleIdleCheckTimerFired()
        }
        // `.common` so this keeps firing during modal UI tracking loops
        // (menus, sheets) — the default run-loop mode alone would pause it.
        RunLoop.main.add(timer, forMode: .common)
        idleCheckTimer = timer
    }

    /// `Timer`'s block-based API isn't statically known to run on
    /// `MainActor` even though `RunLoop.main` guarantees the main thread —
    /// same pattern as `lockFromMainQueueCallback` below.
    nonisolated private func handleIdleCheckTimerFired() {
        MainActor.assumeIsolated { checkIdleAndLockIfNeeded() }
    }

    private func checkIdleAndLockIfNeeded() {
        // Never lock out from under a live recording, playback, or
        // transcription — this check applies to both branches below.
        guard !isLocked, !isAppBusyProvider() else { return }

        if isAppActiveProvider() {
            // Foregrounded: has the researcher stopped touching Clio's
            // own windows for `idleTimeout`?
            if idleTimeProvider() >= idleTimeout {
                lock()
            }
        } else if let resignedAt = resignedActiveAt,
                  Date().timeIntervalSince(resignedAt) >= idleTimeout {
            // Backgrounded: has it been `idleTimeout` since the app lost
            // focus, with no `handleDidBecomeActive()` in between?
            lock()
        }
    }

    // MARK: - Locking

    private func lock() {
        resignedActiveAt = nil
        guard !isLocked else { return }
        isLocked = true
        lastFailureReason = .none
    }

    // MARK: - Unlocking

    /// Presents the system authentication sheet. Safe to call repeatedly
    /// (e.g. from a "Lås opp" retry button) — guarded against overlapping
    /// calls so a second trigger (idle timer firing mid-prompt, a rapid
    /// foreground/background bounce) never double-presents the sheet.
    ///
    /// Returns the underlying `Task` so tests can `await` its completion
    /// deterministically; production call sites can ignore the result.
    @discardableResult
    func attemptUnlock() -> Task<Void, Never> {
        guard isLocked, !isAuthenticating else {
            return Task {}
        }
        isAuthenticating = true
        lastFailureReason = .none

        return Task { [weak self] in
            guard let self else { return }
            let result = await self.authenticator.authenticate(
                reason: "Lås opp Clio for å se opptak og transkripsjoner."
            )
            self.isAuthenticating = false

            switch result {
            case .success:
                self.isLocked = false
                self.lastFailureReason = .none
            case .failure(let error):
                self.isLocked = true
                self.lastFailureReason = Self.failureReason(for: error)
            }
        }
    }

    private static func failureReason(for error: LAError) -> UnlockFailureReason {
        switch error.code {
        case .userCancel, .systemCancel, .appCancel:
            // User (or the system) dismissed the sheet — not a real
            // failure, don't show an error message. Distinguished from
            // `.authenticationFailed` only by omitting the "wrong
            // password" copy; both leave the user re-showing "Lås opp".
            return .none
        case .authenticationFailed:
            return .authenticationFailed
        case .passcodeNotSet:
            return .noPasscodeSet
        default:
            // .biometryNotAvailable / .biometryNotEnrolled / .biometryLockout
            // / .userFallback and any future cases: `.deviceOwnerAuthentication`
            // already falls back to password internally, so these are not
            // expected to surface as terminal failures in practice. Treat
            // defensively as retryable rather than a hard error.
            return .other
        }
    }

    // MARK: - System observers

    private func registerSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.lockFromMainQueueCallback() }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.lockFromMainQueueCallback() }
        )

        // Screen lock (Cmd+Ctrl+Q, lid close with external display, login
        // window engaging) has no NSWorkspace-level notification — it's
        // only observable via the distributed notification center.
        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.append(
            distributedCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.lockFromMainQueueCallback() }
        )
    }

    /// `NotificationCenter`/`DistributedNotificationCenter` callbacks
    /// registered with `queue: .main` are guaranteed to run on the main
    /// thread, but the compiler can't statically verify that a plain
    /// `NSObjectProtocol`-returning API hops onto `MainActor` — assert it
    /// here rather than making every observer closure `async`.
    nonisolated private func lockFromMainQueueCallback() {
        MainActor.assumeIsolated { lock() }
    }
}
