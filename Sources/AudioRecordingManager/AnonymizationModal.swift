import SwiftUI

// MARK: - Model

private struct CapabilityItem: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Subviews

private struct CapabilityRow: View {
    let text: String
    let isSupported: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSupported ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(isSupported ? Color.green : Color.red)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CapabilitySection: View {
    let title: String
    let systemImage: String
    let tint: Color
    let items: [CapabilityItem]
    let isSupported: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    CapabilityRow(text: item.text, isSupported: isSupported)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(tint)
        }
    }
}

private struct WarningBanner: View {
    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                (Text("Automatisk anonymisering er ")
                    .foregroundStyle(.secondary)
                + Text("ikke tilstrekkelig alene")
                    .fontWeight(.semibold)
                + Text(". Teksten må gjennomgås manuelt av ansvarlig medarbeider før materialet tas i bruk eller deles.")
                    .foregroundStyle(.secondary))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Main Modal

struct AnonymizationModal: View {
    @Binding var isPresented: Bool
    var onConfirm: () -> Void

    @State private var hasAcknowledged = false

    private let supported: [CapabilityItem] = [
        .init(text: "Personnavn"),
        .init(text: "Telefonnummer"),
        .init(text: "Fødselsnummer og D-nummer"),
        .init(text: "E-postadresser"),
    ]

    private let unsupported: [CapabilityItem] = [
        .init(text: "Indirekte identifikatorer (f.eks. stilling kombinert med arbeidssted)"),
        .init(text: "Kallenavn og uformelle navn"),
        .init(text: "Geografisk tilhørighet i små miljøer"),
        .init(text: "Ufullstendige opplysninger som likevel kan identifisere"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Header
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatisk anonymisering")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Les gjennom hva verktøyet gjør og ikke gjør før du fortsetter.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.top, .horizontal], 20)

            Divider()
                .padding(.top, 16)

            // MARK: Body
            ScrollView {
                VStack(spacing: 12) {
                    CapabilitySection(
                        title: "Identifiseres automatisk",
                        systemImage: "checkmark.circle",
                        tint: .green,
                        items: supported,
                        isSupported: true
                    )

                    CapabilitySection(
                        title: "Fanges ikke automatisk",
                        systemImage: "xmark.circle",
                        tint: .red,
                        items: unsupported,
                        isSupported: false
                    )

                    WarningBanner()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(maxHeight: 420)

            Divider()

            // MARK: Footer
            VStack(spacing: 14) {
                Toggle(isOn: $hasAcknowledged) {
                    Text("Jeg forstår at teksten må kontrolleres manuelt")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 10) {
                    Spacer()

                    Button("Avbryt") {
                        hasAcknowledged = false
                        isPresented = false
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)

                    Button("Fortsett med anonymisering") {
                        isPresented = false
                        onConfirm()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasAcknowledged)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .background(.ultraThinMaterial)
    }
}
