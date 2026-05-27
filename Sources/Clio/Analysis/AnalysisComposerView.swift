// AnalysisComposerView.swift
// Clio
//
// Column 3 of the Analyser tab when no existing analysis is selected.
// The researcher picks one or more transcripts, picks a prompt template,
// optionally types a research-context line, and starts the run.
//
// Run orchestration lives here too (rather than in a separate
// "controller"): given how linear the flow is — render prompt, persist
// manifest, call Ollama, persist result, audit — adding a controller
// layer would be more boilerplate than clarity.

import SwiftUI

// MARK: - Run state

private enum ComposerRunState: Equatable {
    case idle
    case running(progressText: String)
    case failed(String)
}

// MARK: - View

struct AnalysisComposerView: View {

    /// Bound to `MainView.selectedAnalysisId` — flipped to the new id
    /// after a successful run so the column-3 detail view immediately
    /// shows the result.
    @Binding var selectedAnalysisId: UUID?

    @AppStorage("analysis.llmModel") private var llmModel = "qwen3:8b"
    private var ollamaModelId: String { LLMModel.from(storedValue: llmModel).ollamaId }

    @State private var researchContext: String = ""
    @State private var availableRecordings: [PickerRecording] = []
    @State private var selectedRecordingIds: Set<UUID> = []
    @State private var selectedTemplateId: String = "single-interview-themes-v1"
    @State private var runState: ComposerRunState = .idle
    @State private var runTask: Task<Void, Never>?

    /// Picker row payload: just what we need for selection. Filled from
    /// `RecordingStore.shared.loadAll()` filtered by `transcript.status == .done`.
    private struct PickerRecording: Identifiable, Hashable {
        let id: UUID
        let displayName: String
        let createdAt: Date

        var subtitle: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: createdAt)
        }
    }

    /// Derived from current selection size.
    private var resolvedKind: AnalysisKind {
        selectedRecordingIds.count >= 2 ? .group : .single
    }

    /// Templates relevant to the current resolved kind, with the selected
    /// template id automatically corrected if the user switched between
    /// single and group and the old template no longer applies.
    private var visibleTemplates: [PromptTemplate] {
        PromptTemplateLibrary.shared.templates(for: resolvedKind)
    }

    private var canRun: Bool {
        if case .running = runState { return false }
        return !selectedRecordingIds.isEmpty && !visibleTemplates.isEmpty
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                header
                researchContextSection
                transcriptPickerSection
                templatePickerSection
                runButton
                runStateBanner
                Spacer(minLength: AppSpacing.xxl)
            }
            .padding(AppSpacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { reloadRecordings() }
        .onChange(of: selectedRecordingIds) { _, _ in resyncTemplate() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Ny analyse")
                .font(.clioH1)
            Text("Velg en eller flere transkripsjoner, en analyse-mal, og kjør analysen lokalt via Ollama.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var researchContextSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            sectionLabel("Forskningskontekst (valgfritt)")
            Text("Én eller to setninger om hva studien handler om. Gir LLM-en bedre forutsetninger for å tolke materialet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $researchContext)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 120)
                .padding(AppSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        }
    }

    private var transcriptPickerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                sectionLabel("Velg transkripsjon(er)")
                Spacer()
                if !availableRecordings.isEmpty {
                    Text(selectionStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if availableRecordings.isEmpty {
                ContentUnavailableView(
                    "Ingen transkripsjoner ennå",
                    systemImage: "doc.text",
                    description: Text("Kjør NB-Whisper på et lydopptak før du starter en analyse.")
                )
                .frame(minHeight: 160)
            } else {
                VStack(spacing: 4) {
                    ForEach(availableRecordings) { rec in
                        transcriptPickerRow(rec)
                    }
                }
                .padding(AppSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }

    private func transcriptPickerRow(_ rec: PickerRecording) -> some View {
        let isSelected = selectedRecordingIds.contains(rec.id)
        return Button {
            if isSelected {
                selectedRecordingIds.remove(rec.id)
            } else {
                selectedRecordingIds.insert(rec.id)
            }
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? AppColors.accent : .secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.displayName)
                        .font(.clioSubMedium)
                    Text(rec.subtitle)
                        .font(.clioLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, AppSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectionStatusText: String {
        let n = selectedRecordingIds.count
        if n == 0 { return "Ingen valgt" }
        if n == 1 { return "1 valgt → Enkeltanalyse" }
        return "\(n) valgt → Gruppeanalyse"
    }

    private var templatePickerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            sectionLabel("Velg analyse-mal")
            if visibleTemplates.isEmpty {
                Text("Ingen maler tilgjengelig for valgt kombinasjon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selectedTemplateId) {
                    ForEach(visibleTemplates) { template in
                        Text(template.displayName).tag(template.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if let template = visibleTemplates.first(where: { $0.id == selectedTemplateId }) {
                    Text(template.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var runButton: some View {
        HStack(spacing: AppSpacing.md) {
            switch runState {
            case .running:
                Button(role: .destructive) {
                    runTask?.cancel()
                } label: {
                    Label("Avbryt", systemImage: "stop.circle")
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                }
                .buttonStyle(.bordered)
            default:
                Button {
                    startRun()
                } label: {
                    Label("Kjør analyse", systemImage: "sparkles")
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var runStateBanner: some View {
        switch runState {
        case .idle:
            EmptyView()
        case .running(let progressText):
            HStack(spacing: AppSpacing.sm) {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(Color.gray.opacity(0.06))
            )
        case .failed(let msg):
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(AppColors.destructive.opacity(0.08))
            )
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .clioSectionLabel()
    }

    // MARK: - Data loading

    private func reloadRecordings() {
        let metas = RecordingStore.shared.loadAll().filter { $0.transcript.status == .done }
        availableRecordings = metas
            .sorted { $0.createdAt > $1.createdAt }
            .map { PickerRecording(id: $0.id, displayName: $0.displayName, createdAt: $0.createdAt) }
        resyncTemplate()
    }

    /// When the selection size flips between 1 and ≥2 the available
    /// template list may change. Snap `selectedTemplateId` back to the
    /// first visible template if the previously-selected one is no
    /// longer applicable.
    private func resyncTemplate() {
        guard !visibleTemplates.isEmpty else { return }
        if !visibleTemplates.contains(where: { $0.id == selectedTemplateId }) {
            selectedTemplateId = visibleTemplates[0].id
        }
    }

    // MARK: - Run orchestration

    private func startRun() {
        guard let template = visibleTemplates.first(where: { $0.id == selectedTemplateId }) else {
            runState = .failed("Ingen mal valgt.")
            return
        }

        let kind = resolvedKind
        let sourceIds = Array(selectedRecordingIds)

        runState = .running(progressText: "Forbereder analyse …")
        runTask?.cancel()
        runTask = Task {
            do {
                let analysis = try await performRun(
                    template: template,
                    kind: kind,
                    sourceIds: sourceIds
                )
                await MainActor.run {
                    runState = .idle
                    selectedAnalysisId = analysis.id
                    selectedRecordingIds = []
                    researchContext = ""
                }
            } catch is CancellationError {
                await MainActor.run { runState = .failed("Analysen ble avbrutt.") }
            } catch let err as OllamaAnalysisError {
                await MainActor.run { runState = .failed(err.localizedDescription) }
            } catch {
                await MainActor.run { runState = .failed(error.localizedDescription) }
            }
        }
    }

    /// The full create-render-persist-call-persist-audit flow. Pulled
    /// out of `startRun` for readability.
    private func performRun(
        template: PromptTemplate,
        kind: AnalysisKind,
        sourceIds: [UUID]
    ) async throws -> Analysis {
        // 1. Assemble sources with transcript hashes and display names.
        await MainActor.run {
            runState = .running(progressText: "Leser transkripsjoner …")
        }
        var sources: [AnalysisSource] = []
        var renderedSources: [(displayName: String, text: String)] = []
        for id in sourceIds {
            guard let meta = try RecordingStore.shared.load(id: id) else {
                throw NSError(
                    domain: "AnalysisComposer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Fant ikke opptak \(id.uuidString)."]
                )
            }
            let txtURL = StorageLayout.transcriptURL(id: id)
            guard let text = try? String(contentsOf: txtURL, encoding: .utf8) else {
                throw NSError(
                    domain: "AnalysisComposer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Mangler transcript.txt for \(meta.displayName)."]
                )
            }
            let hash = TranscriptHash.hash(text: text)
            sources.append(AnalysisSource(
                recordingId: id,
                transcriptHash: hash,
                displayName: meta.displayName
            ))
            renderedSources.append((displayName: meta.displayName, text: text))
        }
        try Task.checkCancellation()

        // 2. Render the prompt.
        await MainActor.run {
            runState = .running(progressText: "Bygger forespørsel til \(ollamaModelId) …")
        }
        let context: PromptRenderContext
        switch kind {
        case .single:
            context = PromptRenderContext(
                researchContext: researchContext,
                kind: .single,
                transcript: renderedSources[0].text,
                concatenatedTranscripts: "",
                interviewCount: 1
            )
        case .group:
            context = PromptRenderContext(
                researchContext: researchContext,
                kind: .group,
                transcript: "",
                concatenatedTranscripts: GroupTranscriptAssembly.concatenate(renderedSources),
                interviewCount: renderedSources.count
            )
        }
        let renderedPrompt = template.render(context: context)
        try Task.checkCancellation()

        // 3. Create the manifest with status .pending → .running.
        var analysis = Analysis.new(
            kind: kind,
            sources: sources,
            promptTemplateId: template.id,
            model: ollamaModelId
        )
        try AnalysisStore.shared.create(analysis)
        try AnalysisStore.shared.savePrompt(renderedPrompt, id: analysis.id)
        analysis.status = .running
        analysis.startedAt = Date()
        try AnalysisStore.shared.save(analysis)

        // 4. Call Ollama.
        await MainActor.run {
            runState = .running(progressText: "Kjører \(ollamaModelId) lokalt — dette kan ta noen minutter …")
        }
        do {
            try Task.checkCancellation()
            let result = try await OllamaAnalysisService.shared.analyse(
                prompt: renderedPrompt,
                model: ollamaModelId
            )
            try Task.checkCancellation()

            // 5. Persist result + flip manifest to .completed.
            try AnalysisStore.shared.saveResult(result, id: analysis.id)
            analysis.status = .completed
            analysis.completedAt = Date()
            try AnalysisStore.shared.save(analysis)

            // 6. Audit log (B8: extended payload).
            AuditLogger.shared.log(.transcriptAnalysed, payload: [
                "analysisId": .string(analysis.id.uuidString),
                "kind": .string(analysis.kind.rawValue),
                "sourceCount": .int(analysis.sources.count),
                "model": .string(analysis.model),
                "promptTemplateId": .string(template.id),
            ])

            return analysis
        } catch {
            // Mark the manifest failed so the researcher can see what
            // happened in the list; don't delete it.
            analysis.status = .failed
            analysis.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            analysis.completedAt = Date()
            try? AnalysisStore.shared.save(analysis)
            throw error
        }
    }
}
