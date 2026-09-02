// BiometricAuthenticator.swift
// Clio
//
// Thin wrapper around `LocalAuthentication` so `AppLockManager`'s state
// machine (idle timer, lock triggers, LAError handling) can be unit-tested
// without touching real Touch ID hardware or presenting a system sheet.
//
// Policy choice: `.deviceOwnerAuthentication`, not
// `.deviceOwnerAuthenticationWithBiometrics`. The former makes macOS
// present its native Touch ID sheet *with an automatic password fallback
// built in* — no custom password UI needs to be built or secured by this
// app. It degrades correctly with zero extra branching on our part:
//   - Touch ID enrolled            → biometric prompt, password button always available.
//   - Touch ID not enrolled/locked → system sheet goes straight to password.
//   - No Touch ID hardware at all  → system sheet is password-only.

import Foundation
import LocalAuthentication

/// A single successful/failed authentication attempt, abstracted so
/// `AppLockManager` can be driven by a fake implementation in tests.
protocol BiometricAuthenticating {
    /// Kind of biometry available on this Mac, for lock-screen copy/icon
    /// only (e.g. show a Touch ID glyph vs a generic lock icon). Never
    /// used to decide *whether* to attempt authentication — that's always
    /// attempted via `.deviceOwnerAuthentication`, which handles the
    /// no-biometry case itself.
    var biometryType: LABiometryType { get }

    /// Presents the system authentication sheet (Touch ID with automatic
    /// password fallback) and returns once the user succeeds, cancels, or
    /// the attempt otherwise fails.
    func authenticate(reason: String) async -> Result<Void, LAError>
}

/// Real implementation backed by `LAContext`.
struct LAContextAuthenticator: BiometricAuthenticating {
    var biometryType: LABiometryType {
        // A fresh, uninterrogated context reports `.none` until
        // `canEvaluatePolicy` has been called on it at least once — call
        // it here so `biometryType` reflects the actual hardware/enrollment
        // state for lock-screen copy purposes.
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType
    }

    func authenticate(reason: String) async -> Result<Void, LAError> {
        let context = LAContext()
        // No fallback title override — the system default ("Enter Password…")
        // is already correct and localized by macOS itself.
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .success(())
        } catch let error as LAError {
            return .failure(error)
        } catch {
            // evaluatePolicy(_:localizedReason:) is documented to only ever
            // throw LAError, but guard defensively rather than force-cast.
            return .failure(LAError(.authenticationFailed))
        }
    }
}
