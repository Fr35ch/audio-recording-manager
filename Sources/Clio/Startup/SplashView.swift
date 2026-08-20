import SwiftUI

// Status overlay only — the SVG background is rendered by NSImageView
// in SplashWindowController to guarantee 100% opacity.
struct SplashView: View {

    @ObservedObject var coordinator: StartupCoordinator
    @ObservedObject private var transcriptionService = TranscriptionService.shared
    var onComplete: () -> Void = {}

    @State private var dotCount = 1
    @State private var dotTimer: Timer?

    // Strip trailing ellipsis — we render animated dots instead.
    private var statusText: String {
        let raw: String
        switch coordinator.phase {
        case .systemChecks:
            raw = coordinator.statusMessage.isEmpty ? "Sjekker systemkrav" : coordinator.statusMessage
        case .dependencies:
            raw = coordinator.dependencyManager.statusMessage.isEmpty
                ? "Sjekker avhengigheter"
                : coordinator.dependencyManager.statusMessage
        case .modelLoading:
            raw = coordinator.statusMessage.isEmpty ? "Laster NB-Whisper Large" : coordinator.statusMessage
        case .complete:
            raw = "Klar"
        case .failed(let msg):
            raw = msg
        }
        return raw.hasSuffix("…") ? String(raw.dropLast()) : raw
    }

    private var isLoading: Bool {
        switch coordinator.phase {
        case .complete, .failed: return false
        default: return true
        }
    }

    private var modelBanner: some View {
        Group {
            switch coordinator.phase {
            case .modelLoading:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.75))
                    Text("NB-Whisper Large lastes ned")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(width: 280)
            case .complete:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.8))
                    Text("NB-Whisper Large er lastet ned")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.65))
                }
            default:
                EmptyView()
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.1"
    }

    var body: some View {
        ZStack {
            Color.clear

            // Version — bottom right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("v\(appVersion)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(36)

            // Status line — bottom left
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // Crossfading status text
                    ZStack(alignment: .leading) {
                        Text(statusText)
                            .id(statusText)
                            .transition(.opacity)
                    }
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
                    .animation(.easeInOut(duration: 0.25), value: statusText)

                    // Animated dots — fixed width to avoid layout shift
                    if isLoading {
                        Text(String(repeating: ".", count: dotCount))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(width: 18, alignment: .leading)
                            .animation(.easeInOut(duration: 0.15), value: dotCount)
                    }
                }

                if case .failed = coordinator.phase {
                    Button("Prøv igjen") {
                        Task { await coordinator.retry() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.15))
                    .clipShape(Capsule())
                    .padding(.top, 8)
                }

                modelBanner
            }
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            dotTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
                dotCount = dotCount % 3 + 1
            }
        }
        .onDisappear {
            dotTimer?.invalidate()
            dotTimer = nil
        }
        .onChange(of: coordinator.isComplete) { _, complete in
            if complete { onComplete() }
        }
    }
}

#if DEBUG
struct SplashView_Previews: PreviewProvider {
    static var previews: some View {
        SplashView(coordinator: StartupCoordinator())
            .frame(width: 680, height: 420)
    }
}
#endif
