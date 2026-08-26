// AvidentifiseringSheet.swift
// Clio
//
// De-identification (avidentifisering) UI for the transcript editor.
// Presented as a sheet from the editor toolbar so the editor surface
// stays focused on editing. Inside the sheet:
//
//   - Status header (state badge + date + stats)
//   - Idle / running / failed states with their controls
//   - When complete: tab switcher [Original | Avidentifisert] with the
//     text loaded from disk in a scrollable, selectable pane
//   - "Administrer unntak" button → nested AvidentExceptionsView sheet
//
// Terminology note: file/class names retain `Anonymization` semantics
// in some places (`AnonymizationService`, `AnonymizationResult`,
// `transcriptAnonymized` audit event) for back-compat with already-
// written audit logs and existing call sites. The user-visible label
// is "avidentifisering" because we remove direct identifiers while the
// audio remains on disk — under GDPR this is de-identification, not
// anonymisation.
//
// Implements US-T12 (run from editor), US-A3 (compare original vs
// de-identified), US-A8 (global exception list).

// DEPRECATED: Anonymization UX has moved inline into TranscriptEditorView.
// This file is kept for reference and build compatibility but is no longer
// presented from any call site. See TranscriptEditorView.swift.

import SwiftUI

private enum AnonymizationState: Equatable {
    case idle
    case running
    case completed(date: Date, stats: [String: Int])
    case failed(String)
}

private enum CompareTab: String, CaseIterable {
    case original
    case avidentifisert
    case tilGjennomgang
}

struct AvidentifiseringSheet: View {
    let recordingId: UUID
    let isDirty: Bool
    @Binding var isPresented: Bool

    @State private var state: AnonymizationState = .idle
    @State private var task: Task<Void, Never>?
    @State private var showConsentModal = false
    @State private var showExceptionsSheet = false
    @State private var compareTab: CompareTab = .avidentifisert
    /// Populated when a v2 anonymization run returns `flagged_for_review`
    /// tokens — model-uncertain candidates that need researcher review.
    /// Empty on v1 output. Not persisted yet (Phase B.1 scaffold only).
    @State private var flaggedReview: [FlaggedToken] = []

    private let whatIsRemoved = [
        "Navn på personer",
        "Telefonnumre og e-postadresser",
        "Fødselsnumre og d-numre",
        "Steds- og organisasjonsnavn (via NER)",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .sheet(isPresented: $showConsentModal) {
            AnonymizationModal(isPresented: $showConsentModal, onConfirm: runAnonymization)
        }
        .sheet(isPresented: $showExceptionsSheet) {
            AvidentExceptionsView(isPresented: $showExceptionsSheet)
        }
        .onAppear { loadExistingState() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Avidentifisering")
                    .font(.system(size: 15, weight: .semibold))
                statusLine
            }
            Spacer()
            Button("Lukk") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
        }
        .padding(AppSpacing.lg)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .idle:
            Text("Ikke kjørt for denne transkripsjonen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Kjører …").font(.caption).foregroundStyle(.secondary)
            }
        case .completed(let date, let stats):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppColors.success)
                    .font(.caption)
                Text("Kjørt \(date.formatted(date: .abbreviated, time: .shortened)) — \(statsSummary(stats))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                    .font(.caption)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleContent
        case .running:
            runningContent
        case .completed:
            completedContent
        case .failed(let error):
            failedContent(error: error)
        }
    }

    // MARK: Idle

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Hva som fjernes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(whatIsRemoved, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "minus.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppColors.warning)
                            .padding(.top, 2)
                        Text(item)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }
            }

            Text("Avidentifisering fjerner direkte identifikatorer. Dataene forblir personopplysninger så lenge lydopptaket er bevart — dette er ikke fullstendig anonymisering.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
    }

    // MARK: Running

    private var runningContent: some View {
        VStack(spacing: AppSpacing.md) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Avidentifiserer …")
                .font(.system(size: 14, weight: .medium))
            Text("NLP-modellen lastes ved første kjøring – dette kan ta noen sekunder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.lg)
    }

    // MARK: Completed (compare view)

    private var completedContent: some View {
        VStack(spacing: 0) {
            compareTabBar
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.sm)
            Divider()
            compareTabContent
                .padding(AppSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compareTabBar: some View {
        HStack(spacing: 0) {
            tabButton(.original, label: "Original", badge: nil)
            tabButton(.avidentifisert, label: "Avidentifisert", badge: nil)
            tabButton(
                .tilGjennomgang,
                label: "Til gjennomgang",
                badge: flaggedReview.isEmpty ? nil : flaggedReview.count
            )
            Spacer()
        }
    }

    private func tabButton(_ tab: CompareTab, label: String, badge: Int?) -> some View {
        Button {
            compareTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: compareTab == tab ? .semibold : .regular))
                    .foregroundStyle(compareTab == tab ? .primary : .secondary)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppColors.warning))
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm - 2)
            .background(
                compareTab == tab
                    ? AppColors.accent.opacity(0.10)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: AppRadius.small)
            )
        }
        .buttonStyle(.plain)
        .hoverCursor()
    }

    @ViewBuilder
    private var compareTabContent: some View {
        switch compareTab {
        case .original, .avidentifisert:
            textCompareContent
        case .tilGjennomgang:
            flaggedReviewContent
        }
    }

    @ViewBuilder
    private var textCompareContent: some View {
        let payload: (text: String, emptyHint: String) = {
            switch compareTab {
            case .original:
                return (loadOriginalText() ?? "", "Fant ingen original transkripsjon.")
            case .avidentifisert:
                return (loadAnonymizedText() ?? "", "Fant ingen avidentifisert versjon på disk.")
            case .tilGjennomgang:
                return ("", "")  // unreachable — handled in `compareTabContent`
            }
        }()
        if payload.text.isEmpty {
            VStack {
                Spacer()
                Text(payload.emptyHint)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(payload.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppSpacing.md)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(AppRadius.medium)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var flaggedReviewContent: some View {
        if flaggedReview.isEmpty {
            VStack(spacing: AppSpacing.sm) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("Ingen tvilstilfeller for denne transkripsjonen")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(.secondary)
                Text("Modellen var trygg på alle beslutninger. Når den er usikker, vises kandidatene her for manuell gjennomgang.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(flaggedReview, id: \.start) { token in
                        flaggedCard(token)
                    }
                }
                .padding(AppSpacing.md)
            }
        }
    }

    private func flaggedCard(_ token: FlaggedToken) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                Text(token.original)
                    .font(AppFont.bodyMedium)
                Text(token.type)
                    .font(AppFont.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(AppColors.neutralSurfaceStrong))
                Spacer()
                Text("Skår \(String(format: "%.2f", token.score))")
                    .font(AppFont.tableMonoCell)
                    .foregroundStyle(.secondary)
            }
            Text("…\(token.contextSnippet)…")
                .font(AppFont.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(token.signalsSummary)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Phase B.1: decision buttons not wired to persistence yet —
            // disk-side flow lands in Phase B.2 once upstream v2 ships and
            // we can validate against real flagged tokens.
            HStack(spacing: AppSpacing.sm) {
                Button("Behold") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                    .hoverCursor()
                Button("Rediger") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(true)
                    .hoverCursor()
                Spacer()
            }
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .fill(AppColors.neutralSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .strokeBorder(AppColors.neutralBorder, lineWidth: 1)
        )
    }

    // MARK: Failed

    private func failedContent(error: String) -> some View {
        VStack(spacing: AppSpacing.md) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.destructive)
            Text("Feil ved avidentifisering")
                .font(.system(size: 14, weight: .semibold))
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.lg)
    }

    // MARK: - Footer (primary actions)

    private var footer: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                showExceptionsSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Administrer unntak")
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            primaryAction
        }
        .padding(AppSpacing.lg)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state {
        case .idle:
            Button {
                showConsentModal = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shield.lefthalf.filled")
                    Text("Kjør avidentifisering")
                }
                .padding(.horizontal, AppSpacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.destructive)
            .disabled(isDirty)
            .help(isDirty ? "Lagre endringer før avidentifisering" : "")
        case .running:
            Button(role: .destructive) {
                task?.cancel()
                task = nil
                state = .idle
            } label: {
                Text("Avbryt")
                    .padding(.horizontal, AppSpacing.sm)
            }
            .buttonStyle(.bordered)
        case .completed:
            Button {
                showConsentModal = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Kjør på nytt")
                }
                .padding(.horizontal, AppSpacing.sm)
            }
            .buttonStyle(.bordered)
            .disabled(isDirty)
            .help(isDirty ? "Lagre endringer før ny avidentifisering" : "")
        case .failed:
            Button {
                showConsentModal = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Prøv igjen")
                }
                .padding(.horizontal, AppSpacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.destructive)
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

    private func loadOriginalText() -> String? {
        try? String(contentsOf: StorageLayout.transcriptURL(id: recordingId), encoding: .utf8)
    }

    private func loadAnonymizedText() -> String? {
        try? String(contentsOf: StorageLayout.anonymizedTranscriptURL(id: recordingId), encoding: .utf8)
    }

    private func runAnonymization() {
        let txtURL = StorageLayout.transcriptURL(id: recordingId)
        guard let text = try? String(contentsOf: txtURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("Ingen transkripsjon funnet å avidentifisere")
            return
        }

        // Load global exceptions at run-time so freshly-edited list
        // applies without needing to recreate this view.
        let exceptions = AppStateStore.load().avidentExceptions

        state = .running
        task = Task { @MainActor in
            do {
                let raw = try await AnonymizationService.shared.anonymize(transcript: text)
                guard !Task.isCancelled else { return }

                // Apply user's global exception list (post-processing —
                // upstream no-anonymizer doesn't take exceptions natively).
                let afterExceptions = raw.applying(exceptions: exceptions, to: text)
                guard !Task.isCancelled else { return }

                let result = afterExceptions

                // 1. Write de-identified text
                let anonURL = StorageLayout.anonymizedTranscriptURL(id: recordingId)
                try result.anonymizedText.write(to: anonURL, atomically: true, encoding: .utf8)

                // 2. Update sidecar
                _ = try RecordingStore.shared.updateMeta(id: recordingId) { meta in
                    meta.anonymization.status = .done
                    meta.anonymization.completedAt = Date()
                    meta.anonymization.filename = "transcript_anonymized.txt"
                    meta.anonymization.stats = result.stats
                }

                // 3. Audit (keep legacy event name for log back-compat)
                AuditLogger.shared.log(.transcriptAnonymized, payload: [
                    "recordingId": .string(recordingId.uuidString),
                    "stats": .string(statsSummary(result.stats)),
                    "exceptionCount": .int(exceptions.count),
                ])

                state = .completed(date: Date(), stats: result.stats)
                flaggedReview = result.flaggedForReview ?? []
                compareTab = .avidentifisert
            } catch let error as AnonymizationError {
                guard !Task.isCancelled else { return }
                state = .failed(error.errorDescription ?? "Ukjent feil")
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Export to Word (RTF)

    private func statsSummary(_ stats: [String: Int]) -> String {
        AnonymizationMeta.statsSummary(stats)
    }
}
