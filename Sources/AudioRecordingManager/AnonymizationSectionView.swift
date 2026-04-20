// AnonymizationSectionView.swift
// AudioRecordingManager
//
// Anonymization state machine + UI for the transcript editor.
// Moved from RecordingDetailView per RECORDING_DETAIL_VIEW.md.
//
// Runs against the saved (on-disk) transcript text, never in-memory
// working copy. isDirty gates the button.

import SwiftUI

private enum AnonymizationState: Equatable {
    case idle
    case running
    case completed(date: Date, stats: [String: Int])
    case failed(String)
}

struct AnonymizationSectionView: View {
    let recordingId: UUID
    let isDirty: Bool

    @State private var state: AnonymizationState = .idle
    @State private var task: Task<Void, Never>?
    @State private var showModal = false

    private let whatIsRemoved = [
        "Navn på personer",
        "Telefonnumre og e-postadresser",
        "Fødselsnumre og d-numre",
        "Steds- og organisasjonsnavn (via NER)",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Anonymisering")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                switch state {
                case .idle:
                    idleView
                case .running:
                    runningView
                case .completed(let date, let stats):
                    completedView(date: date, stats: stats)
                case .failed(let error):
                    failedView(error: error)
                }
            }
            .padding(AppSpacing.lg)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
        .sheet(isPresented: $showModal) {
            AnonymizationModal(isPresented: $showModal, onConfirm: runAnonymization)
        }
        .onAppear { loadExistingState() }
    }

    // MARK: - States

    private var idleView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Button { showModal = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                    Text("Anonymiser transkripsjon")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.destructive)
            .disabled(isDirty)
            .help(isDirty ? "Lagre endringer før anonymisering" : "")

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
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var runningView: some View {
        VStack(spacing: AppSpacing.md) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Anonymiserer...")
                    .font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity)

            Text("NLP-modellen lastes ved første kjøring – dette kan ta noen sekunder.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                task?.cancel()
                task = nil
                state = .idle
            } label: {
                Text("Avbryt")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    private func completedView(date: Date, stats: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppColors.success)
                Text("Anonymisert \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.success)
            }

            if !stats.isEmpty {
                Text(statsSummary(stats))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button { showModal = true } label: {
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

    private func failedView(error: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                Text("Feil ved anonymisering")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.destructive)
            }

            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button { showModal = true } label: {
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

    // MARK: - Logic

    private func loadExistingState() {
        do {
            if let meta = try RecordingStore.shared.load(id: recordingId),
               meta.anonymization.status == .done,
               let date = meta.anonymization.completedAt {
                state = .completed(date: date, stats: meta.anonymization.stats ?? [:])
            }
        } catch {}
    }

    private func runAnonymization() {
        let txtURL = StorageLayout.transcriptURL(id: recordingId)
        guard let text = try? String(contentsOf: txtURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("Ingen transkripsjon funnet å anonymisere")
            return
        }

        state = .running
        task = Task { @MainActor in
            do {
                let result = try await AnonymizationService.shared.anonymize(transcript: text)
                guard !Task.isCancelled else { return }

                // 1. Write anonymized text
                let anonURL = StorageLayout.anonymizedTranscriptURL(id: recordingId)
                try result.anonymizedText.write(to: anonURL, atomically: true, encoding: .utf8)

                // 2. Update sidecar
                _ = try RecordingStore.shared.updateMeta(id: recordingId) { meta in
                    meta.anonymization.status = .done
                    meta.anonymization.completedAt = Date()
                    meta.anonymization.filename = "transcript_anonymized.txt"
                    meta.anonymization.stats = result.stats
                }

                // 3. Audit
                AuditLogger.shared.log(.transcriptAnonymized, payload: [
                    "recordingId": .string(recordingId.uuidString),
                    "stats": .string(statsSummary(result.stats)),
                ])

                state = .completed(date: Date(), stats: result.stats)
            } catch let error as AnonymizationError {
                guard !Task.isCancelled else { return }
                state = .failed(error.errorDescription ?? "Ukjent feil")
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func statsSummary(_ stats: [String: Int]) -> String {
        let parts = stats.compactMap { (key, count) -> String? in
            guard count > 0 else { return nil }
            switch key {
            case "NAVN": return "\(count) navn"
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
}
