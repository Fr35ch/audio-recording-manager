import Foundation
import SwiftUI

// MARK: - Analyse Screen
struct AnalyseScreen: View {
    @Binding var selectedAnalysisId: UUID?

    private let listColumnWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            AnalysisListColumn(selectedAnalysisId: $selectedAnalysisId)
                .frame(width: listColumnWidth)

            Divider()

            AnalysisDetailColumn(selectedAnalysisId: $selectedAnalysisId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
