import SwiftUI

// MARK: - Audio Waveform Icon (Custom SVG)
struct AudioWaveformIcon: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Canvas { context, size in
            let fillColor = colorScheme == .dark ? Color.white : Color(red: 32/255, green: 39/255, blue: 51/255)

            // Scale factor to fit 431.77x233.48 viewBox into the given size
            let scale = min(size.width / 431.77, size.height / 233.48)
            let xOffset = (size.width - 431.77 * scale) / 2
            let yOffset = (size.height - 233.48 * scale) / 2

            context.translateBy(x: xOffset, y: yOffset)
            context.scaleBy(x: scale, y: scale)

            // Bar 1: Medium height (left)
            context.fill(
                Path(roundedRect: CGRect(x: 0, y: 50.61, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 2: Short height
            context.fill(
                Path(roundedRect: CGRect(x: 50.11, y: 0, width: 31.11, height: 152.59), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 3: Medium height
            context.fill(
                Path(roundedRect: CGRect(x: 100.22, y: 50.61, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 4: Full height (tallest)
            context.fill(
                Path(roundedRect: CGRect(x: 150.72, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 5: Short height (center)
            context.fill(
                Path(roundedRect: CGRect(x: 200.83, y: 0, width: 31.11, height: 152.59), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 6: Medium height
            context.fill(
                Path(roundedRect: CGRect(x: 250.94, y: 50.6, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 7: Full height (tallest)
            context.fill(
                Path(roundedRect: CGRect(x: 300.44, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 8: Very short height
            context.fill(
                Path(roundedRect: CGRect(x: 350.55, y: 50.6, width: 31.11, height: 101.99), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 9: Full height (tallest, right)
            context.fill(
                Path(roundedRect: CGRect(x: 400.66, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )
        }
        .aspectRatio(431.77/233.48, contentMode: .fit)
    }
}

// MARK: - Navigation Panel (left-most narrow column)
struct NavPanel: View {
    @Binding var selectedTab: AppTab
    @Binding var showAbout: Bool

    @State private var isDarkMode: Bool = NSApp.effectiveAppearance.name == .darkAqua

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            VStack(spacing: 4) {
                navItem(tab: .record, label: "Ta opp lyd", icon: "mic.fill")
                navItem(tab: .recordings, label: "Bibliotek", icon: "books.vertical.fill")
                navItem(tab: .mobileTransfer, label: "Importer fra iPhone", icon: "iphone.and.arrow.forward")
            }
            .padding(.horizontal, 6)
            .padding(.top, 20)

            Spacer()

            Divider().padding(.horizontal, 6)
            footerBlock
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var footerBlock: some View {
        VStack(spacing: 4) {
            footerIconButton(
                icon: isDarkMode ? "sun.max" : "moon",
                helpText: isDarkMode ? "Light mode" : "Dark mode",
                action: toggleAppearance
            )
            footerIconButton(
                icon: "gearshape",
                helpText: "Innstillinger",
                action: {
                    NotificationCenter.default.post(
                        name: .init("ClioShowSettings"), object: nil)
                }
            )
            footerIconButton(
                icon: "info.circle",
                helpText: "Om Clio",
                action: { showAbout = true }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func footerIconButton(icon: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FooterIconButtonLabel(icon: icon, helpText: helpText)
        }
        .buttonStyle(.plain)
    }

    private func toggleAppearance() {
        isDarkMode.toggle()
        NSApp.appearance = isDarkMode
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }

    private func navItem(tab: AppTab, label: String, icon: String) -> some View {
        Button(action: { selectedTab = tab }) {
            NavItemLabel(tab: tab, selectedTab: selectedTab, icon: icon, label: label)
        }
        .buttonStyle(.plain)
    }
}

// Extracted to a struct so @State for hover can be used (functions can't hold @State).
private struct NavItemLabel: View {
    let tab: AppTab
    let selectedTab: AppTab
    let icon: String
    let label: String

    @State private var isHovered = false

    private var isActive: Bool { selectedTab == tab }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: isActive ? .semibold : .regular))
            .frame(width: 44, height: 36)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.small)
                    .fill(isActive
                        ? AppColors.accent.opacity(0.18)
                        : isHovered
                            ? AppColors.accent.opacity(0.09)
                            : Color.clear
                    )
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .foregroundStyle(isActive
                ? AppColors.accent
                : isHovered
                    ? AppColors.accent.opacity(0.75)
                    : Color.secondary
            )
            .contentShape(Rectangle())
            .help(label)
            .onHover { hovering in
                isHovered = hovering
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
    }
}

private struct FooterIconButtonLabel: View {
    let icon: String
    let helpText: String

    @State private var isHovered = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .frame(width: 44, height: 36)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.small)
                    .fill(isHovered ? AppColors.accent.opacity(0.09) : Color.clear)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .foregroundStyle(isHovered ? AppColors.accent.opacity(0.75) : Color.secondary)
            .contentShape(Rectangle())
            .help(helpText)
            .onHover { hovering in
                isHovered = hovering
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
    }
}
