// LockScreenView.swift
// Clio
//
// Full-screen overlay shown whenever `AppLockManager.shared.isLocked`.
// No custom password field — `.deviceOwnerAuthentication` presents its
// own system sheet (Touch ID with automatic password fallback). This
// view only shows a re-entry point ("Lås opp") and the outcome of the
// last attempt.

import SwiftUI
import LocalAuthentication

struct LockScreenView: View {
    @ObservedObject var lockManager: AppLockManager

    private var isTouchID: Bool {
        lockManager.biometryType == .touchID
    }

    var body: some View {
        ZStack {
            AppColors.windowBackground
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.xl) {
                Image(systemName: isTouchID ? "touchid" : "lock.fill")
                    .font(AppFont.iconEmptyState)
                    .foregroundStyle(AppColors.accent)

                Text(AppCopy.AppLock.lockedTitle)
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(AppColors.textPrimary)

                if let message = failureMessage {
                    Text(message)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColors.warning)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                if lockManager.lastFailureReason != .noPasscodeSet {
                    Button(AppCopy.AppLock.unlockButton) {
                        lockManager.attemptUnlock()
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(AppSpacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Own window/level in front of everything else in the scene —
        // callers overlay this at the root so no real content ever
        // renders behind it while locked. The first unlock attempt is
        // triggered once, deterministically, by `AppLockManager.start()`
        // from `AppDelegate` — not from `onAppear` here, whose timing
        // relative to the splash sequence and window visibility isn't
        // guaranteed. This view only handles user-initiated retries.
    }

    private var failureMessage: String? {
        switch lockManager.lastFailureReason {
        case .none:
            return nil
        case .authenticationFailed, .other:
            return AppCopy.AppLock.authenticationFailed
        case .noPasscodeSet:
            return AppCopy.AppLock.noPasscodeSet
        }
    }
}
