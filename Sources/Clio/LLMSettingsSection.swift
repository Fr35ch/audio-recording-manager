// LLMSettingsSection.swift
// Clio
//
// Settings section for LLM model selection. Shown in the main settings sheet.
// Beta models (Borealis) are hidden unless the user has enabled beta access.

import SwiftUI

struct LLMSettingsSection: View {
    @AppStorage("analysis.llmModel") private var llmModelRaw: String = LLMModel.defaultModel.rawValue
    @AppStorage("beta.enabled") private var betaEnabled: Bool = false

    @State private var pullState: PullState = .idle
    @State private var pullProgress: String = ""
    @State private var modelAvailability: [String: Bool] = [:]

    private var selectedModel: LLMModel {
        LLMModel.from(storedValue: llmModelRaw)
    }

    private var availableModels: [LLMModel] {
        LLMModel.available(betaEnabled: betaEnabled)
    }

    enum PullState {
        case idle
        case pulling(modelId: String)
        case done(modelId: String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {

            // MARK: Beta toggle
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Beta-tilgang")
                            .font(.headline)
                        Text("Aktiver for å prøve Borealis — en ny norsk språkmodell fra Nasjonalbiblioteket.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $betaEnabled)
                        .labelsHidden()
                        .onChange(of: betaEnabled) { _, newValue in
                            // If beta is disabled and a beta model is selected, revert to default
                            if !newValue && selectedModel.isBeta {
                                llmModelRaw = LLMModel.defaultModel.rawValue
                            }
                        }
                }
            }

            Divider()

            // MARK: Model picker
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Språkmodell for analyse")
                    .font(.headline)
                Text("Modellen brukes til å analysere transkripsjoner og løse homografer under avidentifisering.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: AppSpacing.sm) {
                    ForEach(availableModels) { model in
                        modelRow(model)
                    }
                }
                .padding(.top, AppSpacing.xs)
            }

            // MARK: Selected-but-not-ready banner
            let isPulled = modelAvailability[selectedModel.ollamaId] ?? false
            if !isPulled && OllamaManager.shared.isInstalled {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(AppColors.warning)
                    Text("«\(selectedModel.displayName)» er ikke lastet ned. Analyse fungerer ikke før modellen er hentet.")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppSpacing.sm)
                .background(AppColors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.small))
            }

            // MARK: Pull progress / result
            if case .pulling(let id) = pullState, id == selectedModel.ollamaId {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(pullProgress.isEmpty ? "Laster ned…" : pullProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.top, AppSpacing.xs)
            }

            if case .done(let id) = pullState, id == selectedModel.ollamaId {
                Label("Modellen er klar til bruk", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.success)
                    .padding(.top, AppSpacing.xs)
            }

            if case .failed(let msg) = pullState {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppSpacing.xs)
            }
        }
        .padding(AppSpacing.lg)
        .task { await refreshAvailability() }
    }


    // MARK: - Model row

    @ViewBuilder
    private func modelRow(_ model: LLMModel) -> some View {
        let isSelected = selectedModel == model
        let isPulled = modelAvailability[model.ollamaId] ?? false

        HStack(alignment: .top, spacing: AppSpacing.md) {
            // Selection radio
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? AppColors.accent : .secondary)
                .font(.system(size: 18))
                .onTapGesture { llmModelRaw = model.rawValue }
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppSpacing.xs) {
                    Text(model.displayName)
                        .fontWeight(.semibold)
                    if model.isBeta {
                        Text("BETA")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AppColors.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(AppColors.accent)
                    }
                    if model.requiresNBLicense {
                        Text("NB-lisens")
                            .font(.system(size: 9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.modelDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppSpacing.xs) {
                    Text("RAM: \(model.estimatedRAM)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if isPulled {
                        Label("Klar til bruk", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppColors.success)
                    } else {
                        Label("Ikke lastet ned", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(isSelected ? AnyShapeStyle(AppColors.warning) : AnyShapeStyle(.tertiary))
                    }
                }
            }

            Spacer()

            // Pull button / status
            if OllamaManager.shared.isInstalled {
                if case .pulling(let id) = pullState, id == model.ollamaId {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Laster ned…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if isPulled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                } else {
                    Button("Last ned") {
                        pullModel(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Text("Ollama ikke installert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppSpacing.sm)
        .background(
            isSelected ? AppColors.accent.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.small)
        )
        .overlay(
            // Red border on selected model that isn't ready
            RoundedRectangle(cornerRadius: AppRadius.small)
                .strokeBorder(isSelected && !isPulled ? AppColors.warning.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { llmModelRaw = model.rawValue }
    }

    // MARK: - Pull action

    private func pullModel(_ model: LLMModel) {
        pullState = .pulling(modelId: model.ollamaId)
        pullProgress = ""
        Task.detached(priority: .utility) {
            do {
                try OllamaManager.shared.pull(model: model) { line in
                    Task { @MainActor in
                        self.pullProgress = line
                    }
                }
                await MainActor.run {
                    pullState = .done(modelId: model.ollamaId)
                }
                await refreshAvailability()
            } catch {
                await MainActor.run {
                    pullState = .failed(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func refreshAvailability() async {
        let models = availableModels
        let avail = await Task.detached(priority: .utility) {
            models.reduce(into: [String: Bool]()) { dict, model in
                dict[model.ollamaId] = OllamaManager.shared.isModelAvailable(model.ollamaId)
            }
        }.value
        modelAvailability = avail
    }
}
