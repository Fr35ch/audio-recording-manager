import SwiftUI

// MARK: - About View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Om Clio")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Version
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Versjon \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Button(action: {
                            if let url = URL(string: "https://github.com/Fr35ch/clio/releases") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12))
                                Text("Se endringslogg")
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(AppColors.accent)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }

                    Divider()

                    // Purpose
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Formål")
                            .font(.headline)
                        Text(
                            "Clio er et verktøy for Nav-innsiktsmedarbeidere som gjennomfører intervjuer. Det støtter opptak, lokal transkribering, taleutskilling, avidentifisering, analyse og opplasting til Teams – alt uten å sende data til eksterne tjenester."
                        )
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Key Features
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Funksjoner")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            FeatureRow(
                                icon: "mic.fill",
                                text: "Lydopptak")
                            FeatureRow(
                                icon: "waveform",
                                text: "Lokal transkribering med NB-Whisper")
                            FeatureRow(
                                icon: "person.2.wave.2",
                                text: "Taleutskilling – identifisering av hvem som snakker")
                            FeatureRow(
                                icon: "person.badge.minus",
                                text: "Avidentifisering av personopplysninger")
                            FeatureRow(
                                icon: "text.magnifyingglass",
                                text: "Analyse av transkripsjonen")
                            FeatureRow(
                                icon: "arrow.up.doc",
                                text: "Opplasting til Teams etter bekreftet avidentifisering")
                        }
                    }

                    Divider()

                    // Quick Start
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Slik kommer du i gang")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Ta opp")
                                .fontWeight(.semibold)
                            Text("   Klikk «Ta opp» for å starte et nytt intervjuopptak.")
                                .foregroundStyle(.secondary)

                            Text("2. Transkriber")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Velg opptaket og klikk «Transkriber» for lokal tale-til-tekst.")
                                .foregroundStyle(.secondary)

                            Text("3. Avidentifiser")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Rediger transkripsjonen og bekreft avidentifisering.")
                                .foregroundStyle(.secondary)

                            Text("4. Analyser")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Bruk analysevertøyet til å trekke ut innsikt fra transkripsjonen.")
                                .foregroundStyle(.secondary)

                            Text("5. Last opp til Teams")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Opplasting blir tilgjengelig etter bekreftet avidentifisering.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.body)
                    }

                    Divider()

                    // Technologies
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Teknologi")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Swift & SwiftUI (macOS 14+)")
                            Text("• AVFoundation – lydopptak")
                            Text("• NB-Whisper via no-transcribe – norsk tale-til-tekst")
                            Text("• no-anonymizer – BERT-basert avidentifisering")
                            Text("• FluidAudio – lokal talegjenkjenning (diarisering)")
                            Text("• Microsoft Graph API – opplasting til Teams")
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Footer
                    Text("© 2026 NAV. Med enerett.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                }
                .padding()
            }
        }
        .frame(width: 600, height: 700)
    }
}

// Helper view for feature rows
struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(AppColors.accent)
                .frame(width: 20)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
        }
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
