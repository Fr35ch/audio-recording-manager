import SwiftUI

// MARK: - Logo geometry (shared with AudioWaveformIcon)
struct LogoBar {
    let x: CGFloat
    let finalY: CGFloat
    let finalHeight: CGFloat
}

let splashLogoBars: [LogoBar] = [
    LogoBar(x: 0,      finalY: 50.61, finalHeight: 182.88),
    LogoBar(x: 50.11,  finalY: 0,     finalHeight: 152.59),
    LogoBar(x: 100.22, finalY: 50.61, finalHeight: 182.88),
    LogoBar(x: 150.72, finalY: 0,     finalHeight: 233.48),
    LogoBar(x: 200.83, finalY: 0,     finalHeight: 152.59),
    LogoBar(x: 250.94, finalY: 50.60, finalHeight: 182.88),
    LogoBar(x: 300.44, finalY: 0,     finalHeight: 233.48),
    LogoBar(x: 350.55, finalY: 50.60, finalHeight: 101.99),
    LogoBar(x: 400.66, finalY: 0,     finalHeight: 233.48),
]
private let logoViewBoxWidth: CGFloat = 431.77
private let logoViewBoxHeight: CGFloat = 233.48
private let splashBarWidth: CGFloat = 31.11
private let splashBarCornerRadius: CGFloat = 15
private let logoCenterY: CGFloat = 233.48 / 2

// Map: which bar index settles for each startup check index
private let checkToBarIndex: [Int] = [0, 8, 1, 7, 2, 6, 3, 5, 4]

// MARK: - Waveform Canvas subview
private struct WaveformCanvas: View {
    let lockedBars: [Bool]
    let failedBarIndex: Int?
    let redAccent: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let scale = min(size.width / logoViewBoxWidth, size.height / logoViewBoxHeight)
                let xOff = (size.width - logoViewBoxWidth * scale) / 2
                let yOff = (size.height - logoViewBoxHeight * scale) / 2
                context.translateBy(x: xOff, y: yOff)
                context.scaleBy(x: scale, y: scale)

                for (i, bar) in splashLogoBars.enumerated() {
                    let isFailed = failedBarIndex == i
                    if lockedBars[i] {
                        let color: Color = isFailed ? redAccent : .white
                        let rect = CGRect(x: bar.x, y: bar.finalY, width: splashBarWidth, height: bar.finalHeight)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: splashBarCornerRadius),
                            with: .color(color)
                        )
                    } else {
                        let fi = Double(i)
                        let rawH = 60.0
                            + sin(t * (1.4 + fi * 0.35) + fi * 0.9) * 55
                            + sin(t * (2.3 + fi * 0.2)) * 35
                            + sin(t * (0.6 + fi * 0.6)) * 20
                        let clampedH = max(20, rawH)
                        let y = logoCenterY - clampedH / 2
                        let rect = CGRect(x: bar.x, y: y, width: splashBarWidth, height: clampedH)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: splashBarCornerRadius),
                            with: .color(.white.opacity(0.7))
                        )
                    }
                }
            }
            .frame(width: 220, height: 220 * logoViewBoxHeight / logoViewBoxWidth)
        }
    }
}

// MARK: - Error overlay subview
private struct ErrorOverlay: View {
    let message: String
    let redAccent: Color
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(redAccent)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Prøv igjen", action: onRetry)
                .buttonStyle(.bordered)
                .foregroundStyle(.white)
        }
    }
}

// MARK: - SplashView
struct SplashView: View {
    @ObservedObject var coordinator: StartupCoordinator
    @State private var lockedBars: [Bool] = Array(repeating: false, count: 9)
    @State private var failedBarIndex: Int? = nil

    private let bgColor = Color(red: 13/255, green: 13/255, blue: 13/255)
    private let redAccent = Color(red: 200/255, green: 16/255, blue: 46/255)

    var body: some View {
        // Wrap in NavigationSplitView with `.detailOnly` so the splash
        // hooks into the same chrome pipeline that gives Lydopptak /
        // Transkripsjoner their correct rounded-corner radius. The
        // sidebar column is never displayed; `EmptyView()` satisfies the
        // init requirement. `.toolbar(removing: .sidebarToggle)` at the
        // outer scope hides the default sidebar-toggle button that
        // NavigationSplitView would otherwise add to the window toolbar.
        NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
            EmptyView()
                .navigationSplitViewColumnWidth(0)
        } detail: {
            ZStack {
                // Full-bleed dark background; OS clips to the window's
                // rounded corners. `ignoresSafeArea()` ensures the colour
                // reaches every window edge so the dark extends all the
                // way out to the rounded frame.
                bgColor
                    .ignoresSafeArea()

                contentStack
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: coordinator.completedCheckIndex) { _, idx in
            guard idx >= 0, idx < checkToBarIndex.count else { return }
            let barIdx = checkToBarIndex[idx]
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                lockedBars[barIdx] = true
            }
        }
        .onChange(of: coordinator.dependencyManager.currentCheck) { _, check in
            let offset = 5
            let barIdx = min(offset + check.rawValue, 8)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                if barIdx < lockedBars.count { lockedBars[barIdx] = true }
            }
        }
        .onChange(of: coordinator.phase) { _, phase in
            if case .failed = phase {
                if let lastLocked = lockedBars.lastIndex(of: true) {
                    failedBarIndex = lastLocked
                }
            } else if case .complete = phase {
                // Lock all remaining unlocked bars with staggered spring animations
                for i in lockedBars.indices where !lockedBars[i] {
                    let delay = Double(i) * 0.08
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                            lockedBars[i] = true
                        }
                    }
                }
            }
        }
    }

    private var contentStack: some View {
        VStack(spacing: 48) {
            Spacer()
            WaveformCanvas(lockedBars: lockedBars, failedBarIndex: failedBarIndex, redAccent: redAccent)
            appNameBlock
            statusBlock
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appNameBlock: some View {
        VStack(spacing: 8) {
            Text("Audio Recording Manager")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text("Nav Arbeids- og velferdsdirektoratet")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var statusBlock: some View {
        VStack(spacing: 16) {
            Text(statusText)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .animation(.easeInOut, value: statusText)
            progressBar
            errorBlock
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.08))
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(redAccent)
                    .frame(width: geo.size.width * overallProgress, height: 3)
                    .animation(.easeInOut(duration: 0.4), value: overallProgress)
            }
        }
        .frame(width: 280, height: 3)
    }

    @ViewBuilder
    private var errorBlock: some View {
        if case .failed(let msg) = coordinator.phase {
            ErrorOverlay(message: msg, redAccent: redAccent) {
                Task { await coordinator.retry() }
            }
        }
    }

    private var statusText: String {
        switch coordinator.phase {
        case .systemChecks:
            return coordinator.statusMessage.isEmpty ? "Sjekker systemkrav…" : coordinator.statusMessage
        case .dependencies:
            return coordinator.dependencyManager.statusMessage.isEmpty ? "Sjekker avhengigheter…" : coordinator.dependencyManager.statusMessage
        case .complete:
            return "Audio Recording Manager er klar"
        case .failed:
            return coordinator.dependencyManager.statusMessage
        }
    }

    private var overallProgress: Double {
        switch coordinator.phase {
        case .systemChecks:
            let total = max(1, coordinator.systemRequirements.count)
            return Double(coordinator.completedCheckIndex + 1) / Double(total) * 0.4
        case .dependencies:
            return 0.4 + coordinator.dependencyManager.overallProgress * 0.6
        case .complete:
            return 1.0
        case .failed:
            return coordinator.dependencyManager.overallProgress * 0.6 + 0.4
        }
    }
}
