// FakeBiometricAuthenticator.swift
// Clio
//
// Test double for `BiometricAuthenticating` so `AppLockManagerTests` can
// drive `AppLockManager`'s state machine deterministically — no real
// Touch ID hardware, no system sheet, no waiting on real timers beyond
// the short intervals tests configure explicitly.

import Foundation
import LocalAuthentication
@testable import Clio

final class FakeBiometricAuthenticator: BiometricAuthenticating {
    var biometryType: LABiometryType = .touchID

    /// What `authenticate(reason:)` resolves to once (optionally) resumed.
    var resultToReturn: Result<Void, LAError> = .success(())

    private(set) var authenticateCallCount = 0

    /// When true, `authenticate(reason:)` suspends until the test calls
    /// `resumePendingAuthentication()` — lets tests exercise the
    /// in-flight-authentication guard (no double system-sheet prompts)
    /// deterministically instead of racing real async timing.
    var suspendsUntilResumed = false
    private var pendingContinuation: CheckedContinuation<Void, Never>?

    func authenticate(reason: String) async -> Result<Void, LAError> {
        authenticateCallCount += 1
        if suspendsUntilResumed {
            await withCheckedContinuation { continuation in
                pendingContinuation = continuation
            }
        }
        return resultToReturn
    }

    /// Lets a suspended `authenticate(reason:)` call proceed to return
    /// `resultToReturn`. No-op if nothing is currently suspended.
    func resumePendingAuthentication() {
        pendingContinuation?.resume()
        pendingContinuation = nil
    }
}
