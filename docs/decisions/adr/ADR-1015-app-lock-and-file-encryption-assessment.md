# ADR-1015: Mandatory App Lock (Touch ID + Password Fallback), No App-Managed File Encryption

**Status**: Accepted

**Date**: 2026-08-31

**Deciders**: Fredrik Scheide, Copilot (planning/implementation partner)

## Context

Clio handles highly sensitive NAV interview recordings and transcripts on
researcher-issued Macs (see AGENTS.md / CLAUDE.md compliance constraints).
Until now, the only barrier between an unattended, unlocked macOS session
and a full library of interview recordings was the operating system's own
screen lock — Clio itself had no concept of being "locked" independent of
the Mac.

### Problem Statement

Two related but distinct problems:

1. **App-level access control**: if a researcher steps away from an
   unlocked Mac (or leaves the app running across a sleep/wake cycle),
   anyone with physical access to the session can open Clio and see
   every recording and transcript in the library, with no additional
   gate beyond whatever the OS itself already enforced.
2. **At-rest file protection**: whether `audio.m4a` / `transcript.txt`
   need their own encryption (a Keychain-backed key, `CryptoKit`) on top
   of what FileVault + the app's sandbox container already provide.

### Forces at Play

**Constraints:**
- The app is SwiftUI-based (`ClioApp`/`AppDelegate` in `main.swift`),
  with two scenes: the main `WindowGroup` and a per-recording
  `transcript-editor` `WindowGroup`.
- `TranscriptionService` / `AnonymizationService` invoke Python CLIs via
  `Foundation.Process`, reading/writing `audio.m4a` / `transcript.txt` as
  plaintext files by path. They have no concept of in-memory decrypted
  bytes.
- `ENABLE_APP_SANDBOX = YES` is already set in the Xcode project —
  recordings live under
  `~/Library/Containers/no.nav.cliotranscribe/Data/...`, inaccessible to
  other processes without the user granting Full Disk Access.
- ADR-1014 already established the storage architecture's core
  principle: *"OS is the security boundary. We rely on macOS per-user
  account isolation + FileVault + MDM-configured sync exclusion — not
  our own crypto."*

**Assumptions:**
- FileVault is mandated on researcher machines (per ADR-1014).
- macOS always requires an account password to be set (so
  `.deviceOwnerAuthentication`'s password fallback is always available in
  practice).

## Decision

### 1. Mandatory, always-on app lock

Clio gates its entire UI behind `LAContext.evaluatePolicy(.deviceOwnerAuthentication,
localizedReason:)` — biometrics (Touch ID) with an **automatic** password
fallback, not a custom password screen. This is not a user-toggleable
setting; it cannot be turned off in Settings.

**Why `.deviceOwnerAuthentication`, not `.deviceOwnerAuthenticationWithBiometrics`:**
the former makes macOS present its native system sheet with password
fallback built in, and degrades correctly with zero app-side branching
for every device-capability case (Touch ID enrolled → biometric prompt
with password button; not enrolled/locked out → straight to password; no
Touch ID hardware at all → password-only sheet). We never build or
secure our own password entry UI.

**Lock triggers:**
- App launch — the app always starts locked; no state is persisted that
  could cause it to start unlocked after a crash or force-quit.
- 5 minutes of inactivity, unified into a single periodic (15s) checker
  (`checkIdleAndLockIfNeeded`) so both cases below share one mechanism
  and consistently respect the busy-state exception (see next bullet):
  - **Backgrounded**: `applicationWillResignActive` records a
    timestamp; `applicationDidBecomeActive` clears it if the user
    returns first. Once `idleTimeout` has elapsed since that timestamp
    with no return, locks. Catches "switched to another app and never
    came back."
    - *Revision note*: the first implementation used a one-shot
      `DispatchWorkItem` scheduled at resign-active time instead of a
      periodic re-check. That design had a real gap: if the app was
      busy (see next bullet) when the one-shot timer fired, it would
      skip locking *once* and then never check again — so a recording
      that finished hours later while still backgrounded would never
      actually lock. Folding this into the same periodic checker as the
      foreground case fixes that.
  - **Foregrounded but idle**: the same periodic check, comparing
    against time since the last interaction with any of Clio's own
    windows (`LocalActivityTracker`, backed by
    `NSEvent.addLocalMonitorForEvents`), active only while Clio remains
    the frontmost app. Catches "left Clio focused and stepped away
    without switching apps" — the case `applicationWillResignActive`
    cannot see at all, since it never fires.
    - *Revision note*: the first implementation of this used
      `CGEventSource.secondsSinceLastEventType` for **system-wide**
      keyboard/mouse idle time. This does not work correctly inside the
      macOS App Sandbox — Apple blocks sandboxed apps from seeing real
      global input timing, and Clio is sandboxed
      (`ENABLE_APP_SANDBOX = YES`). In practice this made the app relock
      almost immediately after every unlock, regardless of real activity.
      Replaced with `LocalActivityTracker`, a local (not global)
      `NSEvent` monitor that only observes events already destined for
      Clio's own windows — this needs no special entitlement and works
      identically inside the sandbox. It's also arguably the more
      correct signal anyway: what matters for an app-level lock is
      disuse of Clio itself, not of the Mac in general.
  - **Busy-state exception**: neither branch above locks while
    `AudioRecorder.shared.isRecording`, `AudioPlayer.shared.isPlaying`,
    or `TranscriptionRunner.shared.inFlight` is non-empty. Added after a
    researcher reported the app locking mid-interview and mid-playback —
    idle keyboard/mouse input (or being backgrounded) is a poor signal
    that the researcher has "left" if Clio is actively recording an
    hour-long interview, playing back audio for review, or transcribing
    in the background; none of those require continuous input. This
    exception deliberately does **not** apply to sleep/screen-lock or
    the manual lock command (see below) — those represent the Mac
    physically going away or an explicit request, not a heuristic that
    could misfire, and continuing an active recording is unaffected by
    locking the *UI* regardless.
  - Both idle-detection branches share the same fixed constant
    (`AppLockManager.defaultIdleTimeout`), not exposed in Settings, to
    keep v1 scope small.
- Immediately on system sleep (`NSWorkspace.willSleepNotification`,
  `.screensDidSleepNotification`) or screen lock
  (`com.apple.screenIsLocked` via `DistributedNotificationCenter` — macOS
  has no public `NSWorkspace`-level API for screen-lock specifically).
  These bypass idle detection *and* the busy-state exception —
  always lock immediately.
- Manually, via a "Lås appen nå" (⌘⌃L) menu command.

**Locked-state UX** (`Security/LockScreenView.swift`): a full-screen
overlay (not a `.sheet`, so nothing can render on top of it) showing a
Touch ID or generic lock glyph, "Clio er låst", and a "Lås opp" retry
button. `LAError` outcomes map to three UI states: silent retry
(`.userCancel`/`.systemCancel`/`.appCancel` — the user or system dismissed
the sheet, not a real failure), an inline "wrong password/Touch ID"
message (`.authenticationFailed` and any unexpected biometry-specific
error, defensively treated as retryable), or a hard, non-retryable
"this Mac has no password" state (`.passcodeNotSet` — the one case
`.deviceOwnerAuthentication` truly cannot recover from).

**Window/content hiding while locked:** the main window's
`sharingType` is set to `.none` while locked (restored to `.readOnly` on
unlock), excluding it from screen recording and Cmd+Tab/Mission Control
previews. Secondary `transcript-editor` windows have no lock overlay of
their own, so `AppDelegate` orders them out entirely while locked and
restores them on unlock. Open sheets (Settings, About, Log Viewer, Design
Showcase) are force-dismissed the instant the app locks, since `.sheet`
renders as its own window layer above any in-view overlay.

### 2. No app-managed file encryption

We explicitly reject adding `CryptoKit`/Keychain-backed encryption for
`audio.m4a` / `transcript.txt`, reinforcing ADR-1014's "OS is the
security boundary" principle rather than reopening it:

1. **FileVault** (mandated) already encrypts data at rest for the
   machine-stolen/disk-removed threat.
2. **App Sandbox container isolation** (already `ENABLE_APP_SANDBOX =
   YES`) means other processes — including another app run by the same
   logged-in user — cannot read Clio's storage without the user granting
   Full Disk Access. This exists today at zero additional cost.
3. The one threat file encryption would additionally close — a second
   process reading the files directly, bypassing Clio's UI, during an
   unlocked session — is a narrower version of the same "unattended,
   unlocked session" threat that app lock (decision 1) already closes for
   anyone going through Clio itself, and direct file access is already
   blocked by point 2.
4. It would reopen exactly the complexity ADR-1014 rejected (key
   derivation, rotation, dev-vs-signed-release Keychain ACL differences),
   **plus a new problem specific to this codebase**: the Python
   subprocess bridges need plaintext files by path. Supporting encryption
   would require decrypting to a temporary plaintext file before every
   transcription/anonymization call and re-encrypting after — a net-new
   attack surface (stray temp plaintext on crash) for marginal benefit.

**If this is ever revisited** (e.g. the FileVault mandate or sandbox
assumption stops holding), the documented fallback is: `SecAccessControlCreateWithFlags`
with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`
(so the key is invalidated if the enrolled Touch ID set changes) gating a
symmetric key in the Keychain, with `CryptoKit.AES.GCM` sealing file
contents. Not building this now.

### Core Principles

1. **The system owns the authentication UI.** We never build, and
   therefore never have to secure, our own password-entry screen.
2. **Lock is a UI gate, not a storage gate.** It protects against
   "someone at the unattended, unlocked session opens Clio," not against
   direct filesystem access — that threat is already covered by FileVault
   + sandbox isolation (decision 2).
3. **Fixed, not configurable, in v1.** The 5-minute timeout and the
   mandatory (non-togglable) nature of the lock are deliberate scope
   decisions to ship a working, unambiguous security posture first.

### Implementation Details

**New files** (`Sources/Clio/Security/`):
- `BiometricAuthenticator.swift` — `BiometricAuthenticating` protocol +
  `LAContextAuthenticator` (real) wrapping `LAContext`. Exists so
  `AppLockManager`'s state machine is unit-testable without real
  hardware.
- `AppLockManager.swift` — `@MainActor` `ObservableObject` singleton:
  `isLocked`, `lastFailureReason`, the single periodic idle-check timer
  (`checkIdleAndLockIfNeeded`), `NSWorkspace`/distributed sleep-lock
  observers, `attemptUnlock()` (guarded against overlapping calls so a
  second trigger never double-presents the system sheet). Also hosts
  `LocalActivityTracker`, the sandbox-safe local-window activity tracker
  backing the foreground idle check (see "Revision note" above).
- `LockScreenView.swift` — the full-screen locked UI, using existing
  `AppColors`/`AppSpacing`/`AppFont`/`GlassButtonStyle` tokens.

**Modified:**
- `main.swift` — `AppDelegate` wires `AppLockManager.shared.start()`,
  `applicationWillResignActive`/`applicationDidBecomeActive`, the "Lås
  appen nå" command, and the window-hiding Combine subscription
  (`observeAppLockState()`).
- `Features/MainView.swift` — overlays `LockScreenView` at the root and
  force-dismisses open sheets on lock.
- `AppCopy.swift` — new `AppLock` copy section (Norwegian UI strings).

**Tests** (`tests/ClioTests/`):
- `FakeBiometricAuthenticator.swift` — test double supporting both
  immediate results and suspend-until-resumed (for testing the
  overlapping-call guard deterministically).
- `AppLockManagerTests.swift` — covers every `LAError` → UX-state
  mapping, the backgrounded-idle path and the foreground idle-time check
  (both via the unified periodic checker, using injectable
  `idleTimeProvider`/`isAppActiveProvider`/`isAppBusyProvider` fakes),
  rapid foreground/background bouncing never locking, the busy-state
  exception in both the foreground and backgrounded branches (including
  a regression test that a busy task finishing while still backgrounded
  locks promptly rather than never, per the one-shot-timer gap noted
  above), manual lock, and the single-prompt guarantee under overlapping
  `attemptUnlock()` calls.

**Not covered by automated tests** (requires a physical Mac with Touch
ID): the actual system sheet's appearance/behavior, real biometric
lockout → password fallback, behavior on Macs with no Touch ID hardware,
real sleep/screen-lock notification timing across macOS versions, and
`sharingType = .none` actually suppressing a real screen recording or
Mission Control preview.

## Consequences

### Positive

- ✅ **Closes the "unattended, unlocked session" gap** that neither
  FileVault nor the app sandbox addressed — this was a real, previously
  unmitigated exposure for a compliance-sensitive app.
- ✅ **No custom password UI to build or secure.** `.deviceOwnerAuthentication`
  owns that surface entirely, including every degraded-capability case.
- ✅ **Small, auditable addition.** No changes to `StorageLayout`,
  `RecordingStore`, `AuditLogger`, or any Python subprocess bridge.

### Negative

- ⚠️ **Zero escape hatch if biometrics is disabled and, in some extreme
  edge case, no account password exists.** macOS requires an account
  password by design, so this is a theoretical rather than practical
  risk, but it is a hard lockout with no in-app recovery if it ever
  occurs.
- ⚠️ **The backgrounded-idle heuristic alone is approximate.** A brief
  Spotlight search or Finder peek counts as "resigned active" and starts
  the 5-minute clock, even though the researcher hasn't really left —
  mitigated somewhat since `applicationDidBecomeActive` cancels it as
  soon as Clio regains focus, so it only matters if the researcher
  genuinely stays away for the full 5 minutes. The foreground idle-time
  check has no such false-positive risk (it only fires on genuine
  keyboard/mouse inactivity), but polls on a 15s interval, so the lock
  can engage up to ~15s later than the exact 5-minute mark.

### Neutral

- 📊 **File encryption remains explicitly out of scope**, consistent
  with, not a reversal of, ADR-1014's "OS is the security boundary"
  stance.

## Alternatives Considered

### Alternative 1: User-toggleable app lock (Settings preference)

**Description**: Let researchers opt in/out of app lock via Settings.

**Rejected because**:
- ❌ Given the sensitivity of the data (NAV interview recordings), an
  optional lock defeats the point — a researcher could disable it and
  the compliance posture reverts to "none."
- ❌ Adds a Settings surface and an extra state to test for no real
  benefit given the data sensitivity involved.

### Alternative 2: Configurable idle timeout

**Description**: Let researchers pick 1/5/15 minutes in Settings.

**Rejected because**:
- ❌ Keeps v1 scope smaller; the single constant
  (`AppLockManager.defaultIdleTimeout`) makes adding a picker later
  trivial if requested.

### Alternative 3: App-managed file encryption (Keychain + CryptoKit)

**Description**: Encrypt `audio.m4a` / `transcript.txt` at rest with a
Keychain-backed key, gated by `kSecAccessControlBiometryCurrentSet`.

**Rejected because**: see "No app-managed file encryption" above — this
mirrors and reinforces ADR-1014's Alternative 2 rejection, with the
additional, codebase-specific problem that the Python subprocess bridges
require plaintext files by path.

## Related Decisions

- ADR-1014: File Storage Architecture Pivot — establishes "OS is the
  security boundary," which this ADR extends to cover session-level
  access as well as storage-level access.

## References

- [Apple: LAPolicy.deviceOwnerAuthentication](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication)
- [Apple: LAError](https://developer.apple.com/documentation/localauthentication/laerror)

## Revision History

- 2026-08-31: Initial decision (Accepted)
