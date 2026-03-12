import SwiftUI

struct AnalysisResultView: View {
    let result: AnalysisResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Analyse")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Lukk") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !result.keyThemes.isEmpty {
                        AnalysisSectionView(
                            title: "Nøkkeltemaer",
                            icon: "tag.fill",
                            items: result.keyThemes
                        )
                    }
                    if !result.keyQuotes.isEmpty {
                        AnalysisSectionView(
                            title: "Viktige sitater",
                            icon: "quote.bubble.fill",
                            items: result.keyQuotes
                        )
                    }
                    if !result.identifiedNeeds.isEmpty {
                        AnalysisSectionView(
                            title: "Identifiserte behov",
                            icon: "lightbulb.fill",
                            items: result.identifiedNeeds
                        )
                    }
                    if !result.opportunities.isEmpty {
                        AnalysisSectionView(
                            title: "Muligheter",
                            icon: "arrow.up.right.circle.fill",
                            items: result.opportunities
                        )
                    }

                    // Raw markdown fallback if all lists are empty
                    if result.keyThemes.isEmpty && result.keyQuotes.isEmpty &&
                       result.identifiedNeeds.isEmpty && result.opportunities.isEmpty {
                        Text(result.rawMarkdown)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                    }

                    // Copy button
                    HStack {
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.rawMarkdown, forType: .string)
                        } label: {
                            Label("Kopier som markdown", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .padding(.bottom, 20)
                }
                .padding(20)
            }
        }
        .background(.ultraThinMaterial)
    }
}

private struct AnalysisSectionView: View {
    let title: String
    let icon: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
