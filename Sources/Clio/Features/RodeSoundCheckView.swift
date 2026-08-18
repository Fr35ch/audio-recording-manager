import SwiftUI

// MARK: - RØDE Status Badge

/// Green pill showing the connected RØDE device name.
struct RodeStatusBadge: View {
    let deviceName: String

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .medium))
            Text(deviceName)
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.xs + 2)
        .background(AppColors.success.opacity(0.85))
        .cornerRadius(AppRadius.large)
    }
}

// MARK: - RØDE VU Meter Row

/// A single channel level bar with label and pass-state indicator.
struct RodeVUMeterRow: View {
    let label: String
    let rms: Float
    let passed: Bool

    // Level zone thresholds
    private let greenMin: Float = 0.01
    private let greenMax: Float = 0.25
    private let yellowMax: Float = 0.70

    private var levelColor: Color {
        if rms < greenMin { return AppColors.neutralBorder }
        if rms < greenMax { return AppColors.success }
        if rms < yellowMax { return AppColors.warning }
        return AppColors.destructive
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            // Channel label — fixed width so bars align
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 180, alignment: .leading)

            // Level bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill(AppColors.neutralSurface)
                        .frame(height: 10)

                    // Fill
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill(levelColor)
                        .frame(
                            width: max(0, CGFloat(rms) * geo.size.width),
                            height: 10
                        )
                        .animation(.easeOut(duration: 0.08), value: rms)
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(height: 20)

            // Pass indicator
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(passed ? AppColors.success : AppColors.neutralBorder)
                .frame(width: 20)
        }
    }
}

// MARK: - RØDE Sound Check View

/// Pre-recording sound check panel shown when a RØDE device is connected.
///
/// Displays the device badge, instruction text, two VU meter rows (left/right channel),
/// and a readiness indicator. All strings are in Norwegian (Bokmål).
struct RodeSoundCheckView: View {
    let deviceName: String?
    @ObservedObject var meterService: RodeSoundCheckService

    private var isReady: Bool {
        meterService.leftPassed && meterService.rightPassed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            // Device status badge
            HStack {
                if let name = deviceName {
                    RodeStatusBadge(deviceName: name)
                } else {
                    RodeStatusBadge(deviceName: "RØDE")
                }
            }

            // Instruction
            Text("Snakk i begge mikrofonene og sjekk at begge kanalene viser grønt nivå")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Channel meters
            VStack(spacing: AppSpacing.sm) {
                RodeVUMeterRow(
                    label: "Intervjuer (venstre kanal)",
                    rms: meterService.leftRMS,
                    passed: meterService.leftPassed
                )
                RodeVUMeterRow(
                    label: "Informant (høyre kanal)",
                    rms: meterService.rightRMS,
                    passed: meterService.rightPassed
                )
            }

            // Readiness text
            HStack(spacing: AppSpacing.xs) {
                if isReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                    Text("Klar til opptak")
                        .foregroundStyle(AppColors.success)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Venter på grønt nivå…")
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(AppSpacing.lg)
        .background(AppColors.neutralSurface)
        .cornerRadius(AppRadius.xlarge)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xlarge)
                .stroke(AppColors.neutralBorder, lineWidth: 1)
        )
    }
}
