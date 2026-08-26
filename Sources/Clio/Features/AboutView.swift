import SwiftUI
import AppKit

// MARK: - About View

/// Simple brand/copyright screen — deliberately minimal. It must never
/// claim features that aren't actually shipped (a prior version listed
/// "Analyse" and named specific tech that had already changed or was
/// disabled — see `AppFeatures.analysisEnabled`). Version and build date
/// are read from values the "Inject Git Commit Hash" build phase writes
/// at build time (`clio-build-info.txt` primary, Info.plist fallback —
/// same dual-source pattern `SidebarPanelContent` below already uses for
/// branch/commit hash).
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var releaseDateText: String {
        let raw = AppRuntimeInfo.buildInfo()?.date
            ?? Bundle.main.infoDictionary?["ClioBuildDate"] as? String
        guard let raw else { return "Ukjent utgivelsesdato" }

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: raw) else { return raw }

        let display = DateFormatter()
        display.dateStyle = .long
        display.locale = Locale(identifier: "nb_NO")
        return display.string(from: date)
    }

    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    private var wordmark: NSImage? {
        guard let url = Bundle.main.url(forResource: "clio-wordmark", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "E91F63"), Color(hex: "8347F0")],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                if let wordmark {
                    Image(nsImage: wordmark)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220)
                } else {
                    Text("Clio")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text("Versjon \(version)")
                        .font(.system(size: 15, weight: .medium))
                    Text("Utgitt \(releaseDateText)")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.white.opacity(0.95))

                Text("© \(currentYear) Arbeids- og velferdsdirektoratet")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(16)
        }
        .frame(width: 420, height: 360)
    }
}

// MARK: - Color(hex:)

/// Scoped to this file — a one-off brand gradient for the About screen,
/// not a reusable design token (`Design/DesignTokens.swift` remains the
/// single source of truth for tokens used elsewhere in the app).
private extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Sidebar Panel
struct SidebarPanelContent: View {
    @Binding var showAbout: Bool
    @Binding var showSidebar: Bool
    let openURL: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Menu")
                .font(.title2)
                .fontWeight(.semibold)
                .padding()

            Divider()

            // Menu items
            VStack(alignment: .leading, spacing: 0) {
                SidebarMenuItem(
                    icon: "link",
                    title: "Brukerinnsikt på Navet",
                    action: {
                        openURL(
                            "https://navno.sharepoint.com/sites/intranett-utvikling/SitePages/Brukerinnsikt.aspx"
                        )
                    }
                )

                SidebarMenuItem(
                    icon: "link",
                    title: "Brukerinnsikt på Aksel",
                    action: {
                        openURL("https://aksel.nav.no/god-praksis/brukerinnsikt")
                    }
                )

                Divider()
                    .padding(.vertical, AppSpacing.sm)

                SidebarMenuItem(
                    icon: "info.circle",
                    title: "Om Clio",
                    action: {
                        showSidebar = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showAbout = true
                        }
                    }
                )
            }

            Spacer()

            // Footer
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Clio – Audio Recording Manager")
                    .font(.caption)
                    .fontWeight(.semibold)
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                let hash = AppRuntimeInfo.buildInfo()?.hash ?? Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "unknown"
                Text("Versjon \(version) (\(hash))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                #if DEBUG
                let branch = AppRuntimeInfo.buildInfo()?.branch ?? Bundle.main.infoDictionary?["GitBranch"] as? String ?? "unknown"
                Text("Debug build • \(branch) • \(hash)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                #endif
            }
            .padding()
        }
        .frame(width: 315, alignment: .leading)
    }
}

// Helper view for sidebar menu items
struct SidebarMenuItem: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill(.ultraThinMaterial)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
