// ExpiryWarningBanner.swift
// AudioRecordingManager
//
// Inline warning banner shown per recording when approaching the 30-day
// automatic deletion. Not dismissible — resolves only when the recording
// is deleted.
//
// See: US-FM-17, PHASE_0_TASKS.md §0F-F3

import SwiftUI

struct ExpiryWarningBanner: View {
    let warningState: ExpiryWarningState
    let isUploaded: Bool

    var body: some View {
        switch warningState {
        case .none:
            EmptyView()

        case .sevenDays(let daysRemaining):
            bannerContent(
                text: "Opptaket slettes automatisk om \(daysRemaining) dager",
                icon: "clock.badge.exclamationmark",
                color: .secondary,
                urgent: false
            )

        case .oneDay:
            bannerContent(
                text: "Opptaket slettes i morgen",
                icon: "exclamationmark.triangle.fill",
                color: AppColors.warning,
                urgent: true
            )

        case .expired:
            EmptyView()
        }
    }

    private func bannerContent(text: String, icon: String, color: Color, urgent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(text)
                    .font(.system(size: 11, weight: urgent ? .semibold : .regular))
                    .foregroundStyle(color)
            }

            if !isUploaded {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.warning)
                    Text("Opptaket er ikke lastet opp")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.warning)
                }
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
    }
}
