// PillButton.swift
// Clio
//
// ⚠️ DESIGN SURFACE — read `Design/README.md` before editing.
//
// Pill button styles + a running-progress pill view. Every action that
// renders as a capsule of fixed `AppSize.pillWidth` × `pillHeight`
// (Bibliotek's TRANSKRIBERING column, future row actions) should go
// through these. Keeps cursor affordance, font, frame, and shape
// consistent across the app.

import SwiftUI

// MARK: - Visual variants

/// Visual variants for `PillButtonStyle`. Pick by semantic intent rather
/// than colour — "destructive" is for irreversible actions, not anything
/// that happens to want a red pill.
enum PillVariant {
    /// Filled accent. Use for the primary action in a context.
    case primary
    /// Outlined neutral (dark grey on a faint grey fill). Use for
    /// secondary actions or for affordances that open something
    /// (e.g. "Åpne").
    case secondary
    /// Outlined accent — running/in-progress state. Use only with
    /// `RunningPill`, not as a generic button style.
    case running
}

// MARK: - PillButtonStyle

/// A `ButtonStyle` that renders the label inside a fixed pill frame
/// (`AppSize.pillWidth` × `pillHeight`) styled per `PillVariant`. Adds a
/// pointing-hand hover cursor automatically.
struct PillButtonStyle: ButtonStyle {
    let variant: PillVariant
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(variant == .primary ? AppFont.pillPrimary : AppFont.pillLabel)
            .foregroundStyle(foreground)
            .frame(width: AppSize.pillWidth, height: AppSize.pillHeight)
            .background(Capsule().fill(hoverFill))
            .overlay(stroke)
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.96 : isHovering ? 1.03 : 1.0)
            .brightness(isHovering && !pressed ? 0.08 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .animation(.easeInOut(duration: 0.08), value: pressed)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }
    }

    private var hoverFill: Color {
        switch variant {
        case .primary:   return isHovering ? AppColors.accent.opacity(0.88) : AppColors.accent
        case .secondary: return isHovering ? AppColors.neutralSurfaceStrong.opacity(0.7) : AppColors.neutralSurfaceStrong
        case .running:   return AppColors.accentTint
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary:   return .white
        case .secondary: return .secondary
        case .running:   return .primary
        }
    }

    @ViewBuilder
    private var stroke: some View {
        switch variant {
        case .primary:
            EmptyView()
        case .secondary:
            Capsule().strokeBorder(AppColors.neutralBorderStrong, lineWidth: 1)
        case .running:
            Capsule().strokeBorder(AppColors.accent.opacity(0.4), lineWidth: 1)
        }
    }
}

// MARK: - RunningPill

/// Indeterminate in-flight pill with elapsed-time label. Tap to cancel.
/// Sized to match `PillButtonStyle` so it slots into the same column without jitter.
struct RunningPill: View {
    let startTime: Date?
    let audioDuration: Double?
    let onCancel: () -> Void

    init(
        startTime: Date? = nil,
        audioDuration: Double? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.startTime = startTime
        self.audioDuration = audioDuration
        self.onCancel = onCancel
    }

    var body: some View {
        Button(action: onCancel) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ZStack {
                    AppColors.accentTint
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(AppFont.pillLabel)
                        Text(pillLabel)
                            .font(AppFont.pillLabel)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.primary)
                }
            }
            .frame(width: AppSize.pillWidth, height: AppSize.pillHeight)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(AppColors.accent.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverCursor()
    }

    private var pillLabel: String {
        guard let start = startTime else { return "Avbryt …" }
        let elapsed = Int(-start.timeIntervalSinceNow)
        let mm = elapsed / 60
        let ss = elapsed % 60
        return String(format: "Avbryt · %d:%02d", mm, ss)
    }
}

// MARK: - TranscriptionProgressView

/// Indeterminate progress block shown in the detail pane during transcription.
/// Shows a spinner, stage label, elapsed time, and an estimated remaining time
/// derived from audio duration × a per-model speed factor.
struct TranscriptionProgressView: View {
    let stageName: String
    let startTime: Date?
    let audioDuration: Double?
    /// NB-Whisper model variant, e.g. "large", "medium". Nil = use safe default.
    var model: String? = nil

    /// Realtime factor (processing time / audio duration) for NB-Whisper on
    /// Apple Silicon MPS (float32). Measured empirically. Values are
    /// conservative (slightly high) so the estimate rarely undershoots —
    /// surprising the user with "done" is better than "5 min left" that
    /// never arrives.
    ///
    /// Previously also scaled by a user-configurable beam count
    /// ("Transkripsjonsnøyaktighet" in Settings) — removed along with that
    /// setting, since WhisperKit has no beam-search parameter to honor it
    /// with (see `CHANGELOG.md`); these factors were measured at what was
    /// always its effective default (3 beams / beamScale 1.0), so the
    /// estimate is unchanged.
    private var realtimeFactor: Double {
        switch model ?? "medium" {
        case "tiny":   return 0.09
        case "base":   return 0.13
        case "small":  return 0.19
        case "medium": return 0.32
        case "large":  return 0.48
        default:       return 0.32
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.75)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine)
                        .font(.body)
                        .monospacedDigit()
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let est = estimateLine {
                    Text(est)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var elapsed: Int {
        guard let start = startTime else { return 0 }
        return max(0, Int(-start.timeIntervalSinceNow))
    }

    private var statusLine: String {
        let e = elapsed
        if e == 0 { return stageName.isEmpty ? "Forbereder…" : stageName }
        let mm = e / 60, ss = e % 60
        let label = stageName.isEmpty ? "Transkriberer" : stageName.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
        return String(format: "%@ · %d:%02d", label, mm, ss)
    }

    private var estimateLine: String? {
        guard let dur = audioDuration, dur > 0, let start = startTime else { return nil }
        let e = -start.timeIntervalSinceNow
        guard e > 5 else { return nil }
        let totalEstimate = dur * realtimeFactor
        let remaining = max(0, totalEstimate - e)
        if remaining < 10 { return "Fullfører snart…" }
        if remaining < 120 {
            return "ca. \(Int(remaining)) sek gjenstår"
        }
        let mins = Int(remaining / 60) + 1
        return "ca. \(mins) min gjenstår"
    }
}
