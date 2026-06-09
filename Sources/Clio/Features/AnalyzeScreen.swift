// AnalyzeScreen.swift
// Clio

import SwiftUI

struct AnalyseScreen: View {
    var body: some View {
        ContentUnavailableView(
            "Analyse kommer snart",
            systemImage: "chart.bar.doc.horizontal",
            description: Text("Analysefunksjonen er under utvikling.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
