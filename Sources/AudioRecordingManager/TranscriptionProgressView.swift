import SwiftUI

// MARK: - Progress View

/// Displayed while a transcription is running.
/// Observes TranscriptionService for live stage/progress updates.
struct TranscriptionProgressView: View {
    @ObservedObject private var service = TranscriptionService.shared
    let onCancel: () -> Void

    @State private var elapsed: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            body_
            Divider()
            footerRow
        }
        .frame(width: 420)
        .background(.ultraThinMaterial)
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            elapsed += 1
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.blue)
            Text("Transkriberer lydopptak")
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: Body

    private var body_: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Stage label + spinner
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.75)
                Text(stageLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .animation(.default, value: stageLabel)
            }

            // Determinate progress bar (hidden at 0 until first stage update)
            if service.progress > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: service.progress)
                        .progressViewStyle(.linear)
                        .animation(.easeInOut(duration: 0.4), value: service.progress)
                    Text("\(Int(service.progress * 100)) %")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // Elapsed time
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Tid brukt: \(formattedElapsed)")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Note about first-run model loading
            if service.stage == .loadingModel || service.stage == .idle {
                Text("Modellen lastes ved første kjøring – dette kan ta et minutt.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: Footer

    private var footerRow: some View {
        HStack {
            Spacer()
            Button("Avbryt") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private var stageLabel: String {
        let name = service.stage.displayName
        return name.isEmpty ? "Forbereder..." : name
    }

    private var formattedElapsed: String {
        let h = Int(elapsed) / 3600
        let m = Int(elapsed) % 3600 / 60
        let s = Int(elapsed) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
