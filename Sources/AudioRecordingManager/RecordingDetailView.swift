import SwiftUI

// MARK: - Anonymization UI state

private enum AnonymizationUIState {
    case notStarted
    case inProgress
    case completed(date: Date, stats: [String: Int])
    case failed(AnonymizationError)
}

// MARK: - Recording Detail View

/// Sheet showing transcript and anonymization controls for a single recording.
///
/// Opened by tapping the detail icon on a RecordingRowView.
struct RecordingDetailView: View {
    let recording: RecordingItem
    let onDismiss: () -> Void

    @State private var metadata: RecordingMetadata? = nil
    @State private var transcriptDraft: String = ""
    @State private var anonymizationState: AnonymizationUIState = .notStarted
    @State private var showAnonymizationModal = false
    @State private var showOriginal: Bool = true
    @State private var anonymizationTask: Task<Void, Never>? = nil
    @State private var startTime: Date? = nil

    private var hasTranscript: Bool { metadata?.originalTranscript != nil }
    private var hasAnonymized: Bool { metadata?.anonymizedTranscript != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                if hasTranscript {
                    anonymizationSection
                }
                transcriptSection
            }
            .padding(32)
        }
        .frame(width: 560)
        .onAppear { loadMetadata() }
        .onDisappear { anonymizationTask?.cancel() }
        .sheet(isPresented: $showAnonymizationModal) {
            AnonymizationModal(isPresented: $showAnonymizationModal, onConfirm: startAnonymization)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(AppColors.accent)

            Text(recording.filename)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            HStack(spacing: AppSpacing.lg) {
                Label(recording.formattedDate, systemImage: "calendar")
                Label(recording.formattedDuration, systemImage: "clock")
                Label(recording.formattedSize, systemImage: "internaldrive")
            }
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transcript Section

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkripsjon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let original = metadata?.originalTranscript {
                // Transcript stored — show it (read-only)
                transcriptContent(
                    text: (showOriginal ? original : metadata?.anonymizedTranscript) ?? original,
                    isAnonymized: !showOriginal && hasAnonymized
                )
            } else {
                // No transcript yet — show paste-in editor
                transcriptInputArea
            }
        }
    }

    private func transcriptContent(text: String, isAnonymized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isAnonymized {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.success)
                    Text("Anonymisert versjon")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.success)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }

            Text(text)
                .font(.system(size: 13, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(isAnonymized ? AppColors.success.opacity(0.05) : Color.gray.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .stroke(
                    isAnonymized ? AppColors.success.opacity(0.25) : Color.gray.opacity(0.2),
                    lineWidth: 1
                )
        )
        .cornerRadius(AppRadius.medium)
    }

    private var transcriptInputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lim inn transkripsjon fra JOJO Transcribe eller annet verktøy:")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)

            TextEditor(text: $transcriptDraft)
                .font(.system(size: 13))
                .frame(minHeight: 140)
                .padding(8)
                .background(Color.gray.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(AppRadius.medium)

            Button(action: saveTranscript) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Lagre transkripsjon")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.accent)
            .disabled(transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Anonymization Section (states A–D)

    private var anonymizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anonymisering")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 16) {
                switch anonymizationState {
                case .notStarted:
                    stateA
                case .inProgress:
                    stateB
                case .completed(let date, let stats):
                    stateC(date: date, stats: stats)
                case .failed(let error):
                    stateD(error: error)
                }
            }
            .padding(16)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // State A — not yet anonymized
    private var stateA: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { showAnonymizationModal = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                    Text("Anonymiser transkripsjon")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.accent)

            VStack(alignment: .leading, spacing: 6) {
                Text("Hva som fjernes:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(whatIsRemoved, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.warning)
                            .padding(.top, 1)
                        Text(item)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // State B — in progress
    private var stateB: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.75)
                Text("Anonymiserer...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)

            Text("NLP-modellen lastes ved første kjøring – dette kan ta noen sekunder.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button(action: cancelAnonymization) {
                Text("Avbryt")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    // State C — completed
    private func stateC(date: Date, stats: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppColors.success)
                Text("Anonymisert \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.success)
            }

            if !stats.isEmpty {
                Text(statsSummary(stats))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // Toggle original / anonymized
            HStack(spacing: 0) {
                toggleButton(label: "Original", icon: "doc.text", selected: showOriginal) {
                    showOriginal = true
                }
                toggleButton(label: "Anonymisert", icon: "shield.lefthalf.filled", selected: !showOriginal) {
                    showOriginal = false
                }
            }
            .background(Color.gray.opacity(0.1))
            .cornerRadius(AppRadius.medium)

            Button(action: { showAnonymizationModal = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Kjør på nytt")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    // State D — error
    private func stateD(error: AnonymizationError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                Text("Feil ved anonymisering")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.destructive)
            }

            Text(error.errorDescription ?? "Ukjent feil")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { showAnonymizationModal = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Prøv igjen")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private func toggleButton(
        label: String, icon: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.white : Color.clear)
            .foregroundStyle(selected ? AppColors.accent : .secondary)
            .cornerRadius(AppRadius.small)
        }
        .buttonStyle(.plain)
    }

    private let whatIsRemoved = [
        "Navn på personer",
        "Telefonnumre og e-postadresser",
        "Fødselsnumre og d-numre",
        "Steds- og organisasjonsnavn (via NER)",
    ]

    private func statsSummary(_ stats: [String: Int]) -> String {
        let parts = stats.compactMap { (key, count) -> String? in
            guard count > 0 else { return nil }
            switch key {
            case "NAVN": return "\(count) \(count == 1 ? "navn" : "navn")"
            case "TELEFON": return "\(count) telefonnummer"
            case "FØDSELSNUMMER": return "\(count) fødselsnummer"
            case "D-NUMMER": return "\(count) d-nummer"
            case "EPOST": return "\(count) e-postadresse"
            case "ORG": return "\(count) organisasjon"
            case "STED": return "\(count) stedsnavn"
            default: return "\(count) \(key.lowercased())"
            }
        }
        if parts.isEmpty { return "Ingen identifiserende informasjon funnet" }
        return parts.joined(separator: ", ") + " fjernet"
    }

    // MARK: - Actions

    private func loadMetadata() {
        let loaded = RecordingMetadataManager.shared.load(for: recording.path)
        metadata = loaded
        if let loaded = loaded, let date = loaded.anonymizationDate {
            anonymizationState = .completed(
                date: date, stats: loaded.anonymizationStats ?? [:]
            )
        }
    }

    private func saveTranscript() {
        let text = transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        RecordingMetadataManager.shared.setOriginalTranscript(text, for: recording.path)
        loadMetadata()
        transcriptDraft = ""
    }

    private func startAnonymization() {
        guard let transcript = metadata?.originalTranscript else { return }
        anonymizationTask?.cancel()
        anonymizationState = .inProgress
        startTime = Date()

        anonymizationTask = Task { @MainActor in
            do {
                let result = try await AnonymizationService.shared.anonymize(transcript: transcript)

                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(startTime ?? Date()) * 1000
                RecordingMetadataManager.shared.applyAnonymizationResult(result, for: recording.path)

                let stableId = URL(fileURLWithPath: recording.path)
                    .deletingPathExtension().lastPathComponent
                AuditLogger.shared.logAnonymization(
                    recordingId: stableId,
                    stats: result.stats,
                    processingTimeMs: elapsed,
                    outcome: .success
                )

                loadMetadata()
                anonymizationState = .completed(
                    date: Date(), stats: result.stats
                )
                showOriginal = false // Show result immediately
            } catch let error as AnonymizationError {
                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(startTime ?? Date()) * 1000
                let stableId = URL(fileURLWithPath: recording.path)
                    .deletingPathExtension().lastPathComponent
                AuditLogger.shared.logAnonymization(
                    recordingId: stableId,
                    stats: nil,
                    processingTimeMs: elapsed,
                    outcome: .error,
                    errorMessage: error.errorDescription
                )
                anonymizationState = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                anonymizationState = .failed(.processFailed(error.localizedDescription))
            }
        }
    }

    private func cancelAnonymization() {
        anonymizationTask?.cancel()
        anonymizationTask = nil
        anonymizationState = .notStarted
    }
}
