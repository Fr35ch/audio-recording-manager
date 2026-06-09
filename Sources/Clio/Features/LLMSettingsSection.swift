// LLMSettingsSection.swift
// Clio
//
// Settings section for LLM model selection. Shown in the main settings sheet.

import SwiftUI

struct LLMSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Text("Innstillinger for analyse kommer snart.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.lg)
    }
}
