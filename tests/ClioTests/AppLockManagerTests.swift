import XCTest
import LocalAuthentication
@testable import Clio

@MainActor
final class AppLockManagerTests: XCTestCase {

    // MARK: - Initial state

    func testStartsLockedOnInit() {
        let manager = AppLockManager(authenticator: FakeBiometricAuthenticator())
        XCTAssertTrue(manager.isLocked)
    }

    func testEachNewInstanceStartsLockedRegardlessOfPriorSession() {
        // Simulates "app relaunched after a forced quit while locked" —
        // no state is persisted that could start the app unlocked.
        let first = AppLockManager(authenticator: FakeBiometricAuthenticator())
        _ = first // prior "session"
        let second = AppLockManager(authenticator: FakeBiometricAuthenticator())
        XCTAssertTrue(second.isLocked)
    }

    // MARK: - Unlock outcomes

    func testSuccessfulAuthenticationUnlocks() async {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(authenticator: fake)

        await manager.attemptUnlock().value

        XCTAssertFalse(manager.isLocked)
        XCTAssertEqual(manager.lastFailureReason, .none)
    }

    func testAuthenticationFailedStaysLockedWithMessage() async {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .failure(LAError(.authenticationFailed))
        let manager = AppLockManager(authenticator: fake)

        await manager.attemptUnlock().value

        XCTAssertTrue(manager.isLocked)
        XCTAssertEqual(manager.lastFailureReason, .authenticationFailed)
    }

    func testUserCancelStaysLockedWithoutErrorMessage() async {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .failure(LAError(.userCancel))
        let manager = AppLockManager(authenticator: fake)

        await manager.attemptUnlock().value

        XCTAssertTrue(manager.isLocked)
        XCTAssertEqual(manager.lastFailureReason, .none, "Cancelling the system sheet shouldn't show an error")
    }

    func testSystemCancelAndAppCancelAlsoStayQuiet() async {
        for code: LAError.Code in [.systemCancel, .appCancel] {
            let fake = FakeBiometricAuthenticator()
            fake.resultToReturn = .failure(LAError(code))
            let manager = AppLockManager(authenticator: fake)

            await manager.attemptUnlock().value

            XCTAssertTrue(manager.isLocked)
            XCTAssertEqual(manager.lastFailureReason, .none)
        }
    }

    func testNoPasscodeSetIsReportedAsHardFailure() async {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .failure(LAError(.passcodeNotSet))
        let manager = AppLockManager(authenticator: fake)

        await manager.attemptUnlock().value

        XCTAssertTrue(manager.isLocked)
        XCTAssertEqual(manager.lastFailureReason, .noPasscodeSet)
    }

    func testUnexpectedBiometryErrorsAreTreatedAsRetryable() async {
        // `.deviceOwnerAuthentication` already falls back to password
        // internally, so these shouldn't surface as terminal failures —
        // but defend against them anyway, as `.other` (retryable).
        for code: LAError.Code in [.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .userFallback] {
            let fake = FakeBiometricAuthenticator()
            fake.resultToReturn = .failure(LAError(code))
            let manager = AppLockManager(authenticator: fake)

            await manager.attemptUnlock().value

            XCTAssertTrue(manager.isLocked)
            XCTAssertEqual(manager.lastFailureReason, .other)
        }
    }

    // MARK: - Concurrency guards

    func testConcurrentAttemptUnlockDoesNotDoublePromptTheSystemSheet() async {
        let fake = FakeBiometricAuthenticator()
        fake.suspendsUntilResumed = true
        fake.resultToReturn = .success(())
        let manager = AppLockManager(authenticator: fake)

        let firstTask = manager.attemptUnlock()
        // Second call arrives while the first is still suspended
        // in-flight (e.g. idle timer firing again mid-prompt, or a rapid
        // foreground/background bounce). Must not present a second sheet.
        let secondTask = manager.attemptUnlock()

        fake.resumePendingAuthentication()
        await firstTask.value
        await secondTask.value

        XCTAssertEqual(fake.authenticateCallCount, 1, "A second overlapping attempt must not re-invoke the authenticator")
        XCTAssertFalse(manager.isLocked)
    }

    // MARK: - Idle timer (backgrounded path, via the periodic checker)

    func testIdleTimerLocksAfterConfiguredTimeout() async throws {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            isAppActiveProvider: { false },
            isAppBusyProvider: { false }
        )
        manager.start()
        try await Task.sleep(nanoseconds: 50_000_000) // let the initial unlock complete
        XCTAssertFalse(manager.isLocked)

        manager.handleWillResignActive()
        XCTAssertFalse(manager.isLocked, "Resigning active alone must not lock immediately")

        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s > 0.05s timeout
        XCTAssertTrue(manager.isLocked)
    }

    func testBecomingActiveBeforeTimeoutCancelsTheLock() async throws {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            isAppActiveProvider: { false },
            isAppBusyProvider: { false }
        )
        manager.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        manager.handleWillResignActive()
        manager.handleDidBecomeActive()

        try await Task.sleep(nanoseconds: 200_000_000) // well past the 0.05s timeout
        XCTAssertFalse(manager.isLocked, "Returning before the idle timeout fires must cancel the pending lock")
    }

    func testRapidForegroundBackgroundSwitchingNeverLocks() async throws {
        // Stress test: resign/become-active bouncing quickly should
        // never lock as long as each resign is followed by a become
        // before the (short, test-only) timeout elapses.
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            isAppActiveProvider: { false },
            isAppBusyProvider: { false }
        )
        manager.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        for _ in 0..<20 {
            manager.handleWillResignActive()
            manager.handleDidBecomeActive()
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(manager.isLocked)
    }

    // MARK: - Foreground idle detection (regression: app never resigns
    // active while the user is simply AFK with Clio still frontmost)

    func testForegroundIdleLocksEvenThoughAppNeverResignsActive() async throws {
        // This is the scenario the backgrounded path alone cannot catch:
        // the app stays the active/frontmost app the whole time (the
        // user just stopped touching the keyboard/mouse), so
        // `applicationWillResignActive`/`handleWillResignActive` is
        // never called at all.
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            idleTimeProvider: { 999 }, // "no input for a very long time"
            isAppActiveProvider: { true },   // "still the frontmost app"
            isAppBusyProvider: { false }
        )
        manager.start()

        try await Task.sleep(nanoseconds: 300_000_000) // several idle-check ticks
        XCTAssertTrue(manager.isLocked)
    }

    func testForegroundIdleCheckIsIgnoredWhileAppIsNotActive() async throws {
        // Backgrounded is handled by `resignedActiveAt`, not the
        // active-state idle-time provider.
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            idleTimeProvider: { 999 },
            isAppActiveProvider: { false },
            isAppBusyProvider: { false }
        )
        manager.start()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(manager.isLocked)
    }

    func testForegroundIdleCheckDoesNotLockWhileUserIsActuallyActive() async throws {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: AppLockManager.defaultIdleTimeout,
            idleCheckInterval: 0.02,
            idleTimeProvider: { 0 }, // "just touched the keyboard"
            isAppActiveProvider: { true },
            isAppBusyProvider: { false }
        )
        manager.start()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(manager.isLocked)
    }

    // MARK: - Busy state suppresses locking (regression: the app must
    // never lock out from under an active recording, playback, or
    // transcription — reported as "it locks all the time" while
    // recording/playing/editing)

    func testNeverLocksWhileForegroundIdleButAppIsBusy() async throws {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            idleTimeProvider: { 999 }, // "no local input for a very long time"
            isAppActiveProvider: { true },
            isAppBusyProvider: { true } // "actively recording/playing/transcribing"
        )
        manager.start()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(manager.isLocked, "Must never lock out from under an active recording/playback/transcription")
    }

    func testNeverLocksWhileBackgroundedAndAppIsBusy() async throws {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            isAppActiveProvider: { false },
            isAppBusyProvider: { true }
        )
        manager.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        manager.handleWillResignActive()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(manager.isLocked, "Backgrounded but still busy (e.g. still recording) must not lock either")
    }

    func testLocksPromptlyOnceBusyTaskFinishesPastAnAlreadyElapsedTimeout() async throws {
        // Regression for a naive one-shot-timer design: if a background
        // timer fired once while busy and simply gave up, a task that
        // finished hours later while still backgrounded would then
        // never actually lock. The periodic checker must keep
        // re-evaluating instead.
        final class ToggleableBusyFlag {
            var isBusy = true
        }
        let busyFlag = ToggleableBusyFlag()
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            isAppActiveProvider: { false },
            isAppBusyProvider: { busyFlag.isBusy }
        )
        manager.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        manager.handleWillResignActive()

        try await Task.sleep(nanoseconds: 200_000_000) // well past idleTimeout, but still busy
        XCTAssertFalse(manager.isLocked, "Still busy — must not have locked yet")

        busyFlag.isBusy = false // "recording finished"
        try await Task.sleep(nanoseconds: 100_000_000) // next tick or two after busy clears
        XCTAssertTrue(manager.isLocked, "Once busy clears, the already-elapsed timeout should lock promptly")
    }

    // MARK: - Manual lock

    func testLockNowLocksImmediatelyAndSynchronously() async {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(authenticator: fake)
        await manager.attemptUnlock().value
        XCTAssertFalse(manager.isLocked)

        manager.lockNow()

        XCTAssertTrue(manager.isLocked)
    }

    func testLockNowCancelsAnyPendingIdleTimer() async throws {
        let fake = FakeBiometricAuthenticator()
        fake.resultToReturn = .success(())
        let manager = AppLockManager(
            authenticator: fake,
            idleTimeout: 0.05,
            idleCheckInterval: 0.02,
            isAppActiveProvider: { false },
            isAppBusyProvider: { false }
        )
        manager.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        manager.handleWillResignActive()
        manager.lockNow()
        // Re-unlock so the (already-locked) manager isn't trivially "locked"
        // by coincidence when the stale idle timer would have fired.
        fake.resultToReturn = .success(())
        await manager.attemptUnlock().value
        XCTAssertFalse(manager.isLocked)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(manager.isLocked, "The idle timer from before lockNow() must not fire later and re-lock")
    }
}
