// TranscriptEditorView.swift
// Clio
//
// Transcript editor with audio-synced karaoke highlighting,
// click-to-seek, and segment-level text editing.
//
// Architecture: see docs/prd/transcription/TRANSCRIPT_EDITOR.md

import AppKit
import AVFoundation
import SwiftUI

// MARK: - Speaker colors (shared with TranscriptionResultView)

private let speakerColors: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .cyan,
]

private func colorForSpeaker(_ speaker: String) -> Color {
    switch speaker {
    case "INTERVJUER": return .blue
    case "INFORMANT":  return .orange
    default:
        let index = abs(speaker.hashValue) % speakerColors.count
        return speakerColors[index]
    }
}

private func formatTimestamp(_ seconds: Double) -> String {
    TranscriptionSegment.formatTimestamp(seconds)
}

private func shortSpeakerLabel(_ speaker: String) -> String {
    TranscriptionSegment.shortSpeakerLabel(speaker)
}

// MARK: - AnonymizationState

private enum AnonymizationState: Equatable {
    case idle
    case running
    case completed(date: Date, stats: [String: Int])
    case failed(String)
}

// MARK: - WordAnnotation

/// Carries per-word display information derived from anonymization redactions.
/// Computed at render time by `wordAnnotations(for:segmentOffset:redactions:)`.
private struct WordAnnotation {
    /// Text to display — original word or the redaction replacement (e.g. `[Navn]`).
    let text: String
    /// True when this word was replaced by the anonymizer; drives the orange background.
    let isRedacted: Bool
}

// MARK: - TranscriptEditorView

struct TranscriptEditorView: View {
    let recordingId: UUID
    let audioURL: URL
    let transcriptionResult: TranscriptionResult

    @StateObject private var playback: TranscriptPlaybackController
    @StateObject private var editor: TranscriptEditorState
    @State private var editingSegmentId: Int? = nil
    @State private var editText: String = ""
    @State private var showUnsavedAlert = false

    @State private var anonymizationState: AnonymizationState = .idle
    @State private var showAnonymized: Bool = false
    @State private var anonymizationTask: Task<Void, Never>?
    @State private var showConsentModal: Bool = false
    @State private var flaggedReview: [FlaggedToken] = []
    @State private var researcherConfirmedAt: Date? = nil
    @State private var anonymizationResult: AnonymizationResult? = nil
    /// Per-segment anonymized text, keyed by segment.id.
    /// Pre-computed once when anonymizationResult is loaded/updated — never inside the render loop.
    @State private var segmentAnonymizedTexts: [Int: String] = [:]
    init(
        recordingId: UUID,
        audioURL: URL,
        transcriptionResult: TranscriptionResult
    ) {
        self.recordingId = recordingId
        self.audioURL = audioURL
        self.transcriptionResult = transcriptionResult
        _playback = StateObject(wrappedValue: TranscriptPlaybackController(audioURL: audioURL))
        _editor = StateObject(wrappedValue: TranscriptEditorState(
            result: transcriptionResult, recordingId: recordingId
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()

            ScrollView {
                segmentContent
            }

            if case .completed = anonymizationState {
                Divider()
                signOffBar
            }

            Divider()
            audioControls
        }
        .sheet(isPresented: $showConsentModal) {
            AnonymizationModal(isPresented: $showConsentModal, onConfirm: runAnonymization)
        }
        .alert("Ulagrede endringer", isPresented: $showUnsavedAlert) {
            Button("Lagre og lukk") {
                Task { await editor.save() }
            }
            Button("Forkast", role: .destructive) {}
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Du har endringer som ikke er lagret. Vil du lagre før du forlater editoren?")
        }
        .onDisappear {
            if editor.isDirty { showUnsavedAlert = true }
            playback.pause()
        }
        .onAppear { loadExistingState() }
        .onReceive(
            NotificationCenter.default.publisher(for: RecordingStore.didChangeNotification)
        ) { note in
            guard (note.object as? UUID) == recordingId else { return }
            // Re-read from disk whenever this recording's sidecar changes.
            // This handles re-transcription resetting anonymization state
            // even when the editor window is already open.
            loadExistingState()
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: AppSpacing.md) {
            anonymizationToolbarSection

            Spacer()

            if editor.isSaving {
                ProgressView().controlSize(.small)
            }

            if let err = editor.saveError {
                Text(err)
                    .font(.clioLabel)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    @ViewBuilder
    private var anonymizationToolbarSection: some View {
        switch anonymizationState {
        case .idle:
            Button {
                showConsentModal = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                    Text("Avidentifiser")
                }
                .font(.clioLabel)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Kjør automatisk avidentifisering for denne transkripsjonen")

        case .running:
            HStack(spacing: AppSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("Avidentifiserer…")
                    .font(.clioLabel)
                    .foregroundStyle(.secondary)
                Button("Avbryt") {
                    anonymizationTask?.cancel()
                    anonymizationTask = nil
                    anonymizationState = .idle
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .completed:
            HStack(spacing: AppSpacing.sm) {
                Picker("", selection: $showAnonymized) {
                    Text("Original").tag(false)
                    Text("Avidentifisert").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)

                Button {
                    showConsentModal = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.clioLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(editor.isSaving)
                .help(editor.isSaving ? "Lagrer…" : "Kjør avidentifisering på nytt")
            }

        case .failed(let msg):
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                    .font(.clioLabel)
                Text(msg)
                    .font(.clioLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Prøv igjen") {
                    showConsentModal = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Segment list

    private var segmentContent: some View {
        let time = playback.currentTime

        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ForEach(editor.result.segments) { segment in
                    VStack(spacing: 0) {
                        if editingSegmentId == segment.id {
                            editableSegmentRow(segment: segment)
                        } else {
                            displaySegmentRow(segment: segment, currentTime: time)
                        }
                        Divider().padding(.leading, 52)
                    }
                    .id(segment.id)
                }
            }
            .padding(.vertical, AppSpacing.sm)
            .onChange(of: currentSegmentId) { _, newId in
                if let id = newId, editingSegmentId == nil {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Display row (read-only, with word-level highlight)

    private func displaySegmentRow(segment: TranscriptionSegment, currentTime: Double) -> some View {
        let isCurrent = segment.start <= currentTime && currentTime < segment.end

        return HStack(alignment: .center, spacing: 12) {
            // Speaker badge — coloured dot + short label ("T1", "T2") so
            // the researcher can scan turn-taking at a glance. Populated
            // by the diarization pass (`SpeakerAlignment.attachSpeakers`).
            speakerBadge(for: segment.speaker)

            // Timestamp gutter — own tap handlers so clicks land directly
            // on it without depending on outer-row fallthrough.
            Text(formatTimestamp(segment.start))
                .font(.clioMonoSmall)
                .foregroundStyle(isCurrent ? AppColors.accent : .secondary)
                .frame(width: 40, alignment: .leading)
                .contentShape(Rectangle())
                .pointingHandCursor()
                .onTapGesture(count: 2) { enterEditMode(for: segment) }
                .onTapGesture(count: 1) { playback.playSegment(from: segment.start, to: segment.end) }

            // Transcript text with karaoke highlight. Words have their own
            // single/double-tap handlers; this wrapper covers whitespace
            // between words and the maxWidth-extended area that the
            // WrappingHStack layout itself does not hit-test.
            wordFlowView(segment: segment, currentTime: currentTime)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .pointingHandCursor()
                .onTapGesture(count: 2) { enterEditMode(for: segment) }
                .onTapGesture(count: 1) { playback.playSegment(from: segment.start, to: segment.end) }

            // Edit button — Buttons absorb taps so the row gestures do
            // not also fire when "Rediger" is clicked.
            Button {
                enterEditMode(for: segment)
            } label: {
                Text("Rediger")
                    .font(.clioLabel)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            isCurrent
                ? AppColors.accent.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.small)
        )
        // Final fallback for clicks in the row's padding (between the
        // inner HStack edge and the row's outer bounds). Children with
        // their own gestures take precedence; this fires only for clicks
        // not consumed above.
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture(count: 2) { enterEditMode(for: segment) }
        .onTapGesture(count: 1) { playback.playSegment(from: segment.start, to: segment.end) }
    }

    /// Shared transition into edit mode — used by the Rediger button, the
    /// row double-click, the timestamp double-click, the word double-click,
    /// and the wordFlow-area double-click. The pause here also clears the
    /// brief audio that count:1 fires immediately before count:2 lands on
    /// a double-click; net effect is a short blip then silence + edit mode.
    private func enterEditMode(for segment: TranscriptionSegment) {
        editingSegmentId = segment.id
        if showAnonymized, let anonText = segmentAnonymizedTexts[segment.id] {
            editText = anonText
        } else {
            editText = segment.text
        }
        playback.pause()
    }

    // MARK: - Word flow (karaoke)

    @ViewBuilder
    private func wordFlowView(segment: TranscriptionSegment, currentTime: Double) -> some View {
        if segment.words.isEmpty {
            // Transcripts don't carry word-level timestamps (navt.py outputs words: []).
            // Render the whole segment as a single hit target.
            // When showAnonymized, swap in the pre-computed anonymized text for this segment.
            // `.textSelection(.enabled)` is dropped on purpose: it absorbs clicks on macOS,
            // blocking playSegment. Selection is still available via the toolbar copy affordance.
            let displayText: String = {
                if showAnonymized, let anonText = segmentAnonymizedTexts[segment.id] {
                    return anonText
                }
                return segment.text.trimmingCharacters(in: .whitespaces)
            }()
            Text(displayText)
                .clioTranscript()
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
        } else {
            // Word-level karaoke path — only reached when the transcription engine
            // has populated word timestamps (future: when navt.py populates words[]).
            let annotations: [WordAnnotation]? = showAnonymized
                ? wordAnnotations(
                    for: segment,
                    segmentOffset: segmentOffset(for: segment, in: editor.result.segments),
                    redactions: anonymizationResult?.redactions ?? []
                )
                : nil

            WrappingHStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segment.words.enumerated()), id: \.offset) { idx, word in
                    let isHighlighted = currentTime >= word.start && currentTime < word.end
                    let annotation: WordAnnotation? = annotations.flatMap {
                        $0.indices.contains(idx) ? $0[idx] : nil
                    }
                    let displayText = annotation?.text ?? word.word
                    let isRedacted = annotation?.isRedacted ?? false
                    Text(displayText)
                        .clioTranscript()
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(
                            isHighlighted && isRedacted ? Color.orange.opacity(0.50)
                                : isRedacted            ? Color.orange.opacity(0.25)
                                : isHighlighted         ? AppColors.accent.opacity(0.25)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                        .contentShape(Rectangle())
                        .pointingHandCursor()
                        .onTapGesture(count: 2) {
                            enterEditMode(for: segment)
                        }
                        .onTapGesture(count: 1) {
                            playback.playSegment(from: word.start, to: segment.end)
                        }
                }
            }
        }
    }

    // MARK: - Edit row

    private func editableSegmentRow(segment: TranscriptionSegment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(formatTimestamp(segment.start))
                    .font(.clioMonoSmall)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                TextEditor(text: $editText)
                    .font(.clioMono)
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.small)
                            .stroke(AppColors.accent.opacity(0.3), lineWidth: 1)
                    )

                HStack(spacing: AppSpacing.sm) {
                    Button("Lagre") {
                        if showAnonymized {
                            // Editing anonymized view: update in-memory cache and persist override
                            let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                            segmentAnonymizedTexts[segment.id] = trimmed
                            saveAnonymizationOverride(segmentId: segment.id, text: trimmed)
                        } else {
                            // Editing original: update canonical text, clear anonymized cache
                            editor.updateSegment(id: segment.id, text: editText)
                            segmentAnonymizedTexts.removeValue(forKey: segment.id)
                            removeAnonymizationOverride(segmentId: segment.id)
                        }
                        editingSegmentId = nil
                        Task { await editor.save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Avbryt") {
                        editingSegmentId = nil
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            AppColors.accent.opacity(0.06),
            in: RoundedRectangle(cornerRadius: AppRadius.small)
        )
    }

    // MARK: - Audio controls

    private var audioControls: some View {
        HStack(spacing: AppSpacing.lg) {
            // Time display
            Text(formatTimestamp(playback.currentTime))
                .font(.clioMonoSmall)
                .foregroundStyle(.secondary)
                .frame(width: 40)

            // Scrubber
            Slider(value: Binding(
                get: { playback.currentTime },
                set: { playback.seek(to: $0) }
            ), in: 0...max(playback.duration, 0.01))
            .controlSize(.small)

            Text(formatTimestamp(playback.duration))
                .font(.clioMonoSmall)
                .foregroundStyle(.secondary)
                .frame(width: 40)

            // Play/pause
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            // Speed selector
            Picker("", selection: Binding(
                get: { playback.playbackRate },
                set: { playback.setRate($0) }
            )) {
                ForEach(TranscriptPlaybackController.availableRates, id: \.self) { rate in
                    Text("\(rate, specifier: "%.2g")×").tag(rate)
                }
            }
            .frame(width: 70)
            .controlSize(.small)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
    }

    // MARK: - Speaker badge

    /// Renders a coloured dot + short label ("T1", "T2") for a segment.
    /// Uses the file-level `colorForSpeaker(_:)` and
    /// `shortSpeakerLabel(_:)` helpers (defined at the top of the file)
    /// so the same colour mapping is shared across views.
    private func speakerBadge(for speaker: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForSpeaker(speaker))
                .frame(width: 8, height: 8)
            Text(shortSpeakerLabel(speaker))
                .font(.clioLabel)
                .foregroundStyle(colorForSpeaker(speaker))
        }
        .frame(width: 80, alignment: .leading)
    }

    // MARK: - Sign-off bar

    private var signOffBar: some View {
        HStack(spacing: AppSpacing.md) {
            if let date = researcherConfirmedAt {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(AppColors.success)
                Text("Gjennomgått og godkjent \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.clioCaption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(AppColors.warning)
                Text("Gjennomgå den avidentifiserte teksten og bekreft at den er klar for deling.")
                    .font(.clioCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if researcherConfirmedAt == nil {
                Button("Godkjenn og signer") {
                    confirmSignOff()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.success)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .background(
            researcherConfirmedAt != nil
                ? AppColors.success.opacity(0.08)
                : AppColors.warning.opacity(0.06)
        )
    }

    // MARK: - Helpers

    private var currentSegmentId: Int? {
        let time = playback.currentTime
        return editor.result.segments.last(where: { $0.start <= time && time < $0.end })?.id
    }

    // MARK: - Anonymization

    /// Resets all in-memory anonymization state. Called when the underlying
    /// transcription is replaced so the editor never shows stale redactions.
    private func resetAnonymizationState() {
        anonymizationTask?.cancel()
        anonymizationTask = nil
        anonymizationState = .idle
        showAnonymized = false
        anonymizationResult = nil
        segmentAnonymizedTexts = [:]
        flaggedReview = []
        researcherConfirmedAt = nil
    }

    private func loadExistingState() {
        // Reset first so a sidecar downgrade (e.g. re-transcription clearing
        // anonymization) is always reflected even when called on an open view.
        anonymizationState = .idle
        researcherConfirmedAt = nil
        anonymizationResult = nil
        segmentAnonymizedTexts = [:]

        do {
            if let meta = try RecordingStore.shared.load(id: recordingId),
               meta.anonymization.status == .done,
               let date = meta.anonymization.completedAt {
                anonymizationState = .completed(date: date, stats: meta.anonymization.stats ?? [:])
                researcherConfirmedAt = meta.anonymization.researcherConfirmedAt
            }
        } catch {}

        if let data = try? Data(contentsOf: StorageLayout.anonymizationResultURL(id: recordingId)),
           let result = try? JSONDecoder().decode(AnonymizationResult.self, from: data) {
            anonymizationResult = result
            segmentAnonymizedTexts = buildSegmentAnonymizedTexts(from: result)
        }

        // Apply any manually saved overrides on top of the auto-generated texts
        if let data = try? Data(contentsOf: StorageLayout.anonymizationOverridesURL(id: recordingId)),
           let overrides = try? JSONDecoder().decode([String: String].self, from: data) {
            for (key, value) in overrides {
                if let intKey = Int(key) {
                    segmentAnonymizedTexts[intKey] = value
                }
            }
        }
    }

    private func confirmSignOff() {
        do {
            _ = try RecordingStore.shared.updateMeta(id: recordingId) { meta in
                meta.anonymization.researcherConfirmedAt = Date()
            }
            researcherConfirmedAt = Date()
            AuditLogger.shared.logAnonymizationConfirmedByResearcher(
                recordingId: recordingId,
                armToolUsed: true
            )
        } catch {}
    }

    private func saveAnonymizationOverride(segmentId: Int, text: String) {
        let url = StorageLayout.anonymizationOverridesURL(id: recordingId)
        var overrides: [String: String] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            overrides = existing
        }
        overrides[String(segmentId)] = text
        if let data = try? JSONEncoder().encode(overrides) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func removeAnonymizationOverride(segmentId: Int) {
        let url = StorageLayout.anonymizationOverridesURL(id: recordingId)
        guard let data = try? Data(contentsOf: url),
              var overrides = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        overrides.removeValue(forKey: String(segmentId))
        if let data = try? JSONEncoder().encode(overrides) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func runAnonymization() {
        let txtURL = StorageLayout.transcriptURL(id: recordingId)
        guard let text = try? String(contentsOf: txtURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            anonymizationState = .failed("Ingen transkripsjon funnet å avidentifisere")
            return
        }

        let exceptions = AppStateStore.load().avidentExceptions

        anonymizationState = .running
        anonymizationTask = Task { @MainActor in
            do {
                let raw = try await AnonymizationService.shared.anonymize(transcript: text)
                guard !Task.isCancelled else { return }

                let afterExceptions = raw.applying(exceptions: exceptions, to: text)
                guard !Task.isCancelled else { return }

                let result = afterExceptions
                guard !Task.isCancelled else { return }

                let anonURL = StorageLayout.anonymizedTranscriptURL(id: recordingId)
                try result.anonymizedText.write(to: anonURL, atomically: true, encoding: .utf8)

                _ = try RecordingStore.shared.updateMeta(id: recordingId) { meta in
                    meta.anonymization.status = .done
                    meta.anonymization.completedAt = Date()
                    meta.anonymization.filename = "transcript_anonymized.txt"
                    meta.anonymization.stats = result.stats
                }

                AuditLogger.shared.log(.transcriptAnonymized, payload: [
                    "recordingId": .string(recordingId.uuidString),
                    "stats": .string(statsSummary(result.stats)),
                    "exceptionCount": .int(exceptions.count),
                ])

                anonymizationState = .completed(date: Date(), stats: result.stats)
                anonymizationResult = result
                segmentAnonymizedTexts = buildSegmentAnonymizedTexts(from: result)
                flaggedReview = result.flaggedForReview ?? []
                showAnonymized = true

                if let data = try? JSONEncoder().encode(result) {
                    try? data.write(to: StorageLayout.anonymizationResultURL(id: recordingId), options: .atomic)
                }
            } catch let error as AnonymizationError {
                guard !Task.isCancelled else { return }
                anonymizationState = .failed(error.errorDescription ?? "Ukjent feil")
            } catch {
                guard !Task.isCancelled else { return }
                anonymizationState = .failed(error.localizedDescription)
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
        if parts.isEmpty { return "ingen identifiserende informasjon funnet" }
        return parts.joined(separator: ", ") + " fjernet"
    }

    // MARK: - Word annotation helpers

    /// Splits `result.anonymizedText` by the same `\n\n` separator the anonymizer received,
    /// then maps each slice back to its segment by index. Called once when anonymization
    /// completes or loads — never inside the per-frame render loop.
    private func buildSegmentAnonymizedTexts(from result: AnonymizationResult) -> [Int: String] {
        let lines = result.anonymizedText.components(separatedBy: "\n\n")
        var map: [Int: String] = [:]
        let segments = editor.result.segments
        for (i, segment) in segments.enumerated() {
            if i < lines.count {
                map[segment.id] = lines[i]
            }
        }
        return map
    }

    /// Returns the character offset (in Unicode scalars) of `target`'s text
    /// within the full transcript string that was sent to the anonymizer.
    /// The full text is `segments.map { $0.text.trimmed }.joined(separator: "\n\n")`.
    private func segmentOffset(for target: TranscriptionSegment, in segments: [TranscriptionSegment]) -> Int {
        var offset = 0
        for seg in segments {
            if seg.id == target.id { return offset }
            offset += seg.text.trimmingCharacters(in: .whitespaces).count + 2  // +2 for "\n\n"
        }
        return offset
    }

    /// Builds per-word display annotations for `segment` by matching each
    /// `TranscriptionWord` to the redaction spans returned by the anonymizer.
    /// Words that overlap a redaction are marked `isRedacted = true` and carry
    /// the replacement text (e.g. `[Navn]`); others carry their original text.
    private func wordAnnotations(
        for segment: TranscriptionSegment,
        segmentOffset: Int,
        redactions: [Redaction]
    ) -> [WordAnnotation] {
        let segText = segment.text.trimmingCharacters(in: .whitespaces)
        var annotations: [WordAnnotation] = []
        var charOffset = 0
        var remaining = segText

        for word in segment.words {
            let trimmedWord = word.word.trimmingCharacters(in: .whitespaces)
            guard !trimmedWord.isEmpty else {
                annotations.append(WordAnnotation(text: word.word, isRedacted: false))
                continue
            }

            var matchedRedaction: Redaction? = nil
            if let range = remaining.range(of: trimmedWord) {
                let localStart = charOffset + remaining.distance(from: remaining.startIndex, to: range.lowerBound)
                let localEnd = charOffset + remaining.distance(from: remaining.startIndex, to: range.upperBound)
                let absStart = segmentOffset + localStart
                let absEnd = segmentOffset + localEnd

                for red in redactions where absStart < (red.position + red.length) && absEnd > red.position {
                    matchedRedaction = red
                    break
                }

                charOffset += remaining.distance(from: remaining.startIndex, to: range.upperBound)
                remaining = String(remaining[range.upperBound...])
            }

            annotations.append(WordAnnotation(
                text: matchedRedaction?.replacement ?? word.word,
                isRedacted: matchedRedaction != nil
            ))
        }
        return annotations
    }
}

// MARK: - View helpers

private extension View {
    /// Show the pointing-hand cursor while the mouse hovers this view.
    /// macOS SwiftUI does not flip the cursor automatically for tappable
    /// views — without this, researchers can't tell a segment row is
    /// clickable. Applied to every tap target in the segment row
    /// (timestamp, wordFlow wrapper, outer row, individual words).
    @ViewBuilder
    func pointingHandCursor() -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}

// MARK: - WrappingHStack (flow layout for words)

private struct WrappingHStack: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { sum, row in
            sum + row.height + (sum > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.subview.sizeThatFits(.unspecified)
                item.subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
    }
    private struct Row {
        var items: [RowItem] = []
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        var x: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].items.append(RowItem(subview: subview))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }
}
