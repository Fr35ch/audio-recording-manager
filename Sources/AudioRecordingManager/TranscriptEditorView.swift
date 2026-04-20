// TranscriptEditorView.swift
// AudioRecordingManager
//
// Transcript editor with audio-synced karaoke highlighting,
// click-to-seek, and segment-level text editing.
//
// Architecture: see docs/prd/transcription/TRANSCRIPT_EDITOR.md

import SwiftUI
import AVFoundation

// MARK: - Speaker colors (shared with TranscriptionResultView)

private let speakerColors: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .cyan,
]

private func colorForSpeaker(_ speaker: String) -> Color {
    let index = abs(speaker.hashValue) % speakerColors.count
    return speakerColors[index]
}

private func formatTimestamp(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%d:%02d", m, s)
}

private func shortSpeakerLabel(_ speaker: String) -> String {
    if speaker.hasPrefix("SPEAKER_"), let num = Int(speaker.dropFirst(8)) {
        return "T\(num + 1)"
    }
    return speaker
}

// MARK: - TranscriptEditorView

struct TranscriptEditorView: View {
    let recordingId: UUID
    let audioURL: URL
    let transcriptionResult: TranscriptionResult
    /// Callback to navigate to the linked recording in the Lydopptak tab.
    let onShowLinkedRecording: (() -> Void)?

    @StateObject private var playback: TranscriptPlaybackController
    @StateObject private var editor: TranscriptEditorState
    @State private var editingSegmentId: Int? = nil
    @State private var editText: String = ""
    @State private var showUnsavedAlert = false

    init(
        recordingId: UUID,
        audioURL: URL,
        transcriptionResult: TranscriptionResult,
        onShowLinkedRecording: (() -> Void)? = nil
    ) {
        self.recordingId = recordingId
        self.audioURL = audioURL
        self.transcriptionResult = transcriptionResult
        self.onShowLinkedRecording = onShowLinkedRecording
        _playback = StateObject(wrappedValue: TranscriptPlaybackController(audioURL: audioURL))
        _editor = StateObject(wrappedValue: TranscriptEditorState(
            result: transcriptionResult, recordingId: recordingId
        ))
    }

    private enum EditorTab {
        case transkripsjon
        case analyse
    }

    @State private var selectedEditorTab: EditorTab = .transkripsjon
    @State private var anonymizationExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()

            // Tab bar
            HStack(spacing: 0) {
                tabButton(label: "Transkripsjon", tab: .transkripsjon)
                tabButton(label: "Analyse", tab: .analyse)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.xs)

            Divider()

            // Tab content
            switch selectedEditorTab {
            case .transkripsjon:
                ScrollView {
                    VStack(spacing: 0) {
                        // Collapsible anonymization panel
                        anonymizationPanel
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.sm)

                        Divider()

                        segmentContent
                    }
                }
            case .analyse:
                ScrollView {
                    AnalyseSectionView(
                        recordingId: recordingId,
                        isDirty: editor.isDirty
                    )
                    .padding(AppSpacing.lg)
                }
            }

            Divider()
            audioControls
        }
        .alert("Ulagrede endringer", isPresented: $showUnsavedAlert) {
            Button("Lagre og lukk") {
                Task {
                    await editor.save()
                }
            }
            Button("Forkast", role: .destructive) {
                // Allow navigation — dirty state is abandoned
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Du har endringer som ikke er lagret. Vil du lagre før du forlater editoren?")
        }
        .onDisappear {
            if editor.isDirty {
                showUnsavedAlert = true
            }
            playback.pause()
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: AppSpacing.md) {
            if let onShowLinkedRecording {
                Button {
                    onShowLinkedRecording()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                        Text("Vis opptak")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            if editor.isDirty {
                Text("Ulagrede endringer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }

            if let err = editor.saveError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Button {
                Task { await editor.save() }
            } label: {
                HStack(spacing: 4) {
                    if editor.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Lagre endringer")
                }
            }
            .disabled(!editor.isDirty || editor.isSaving)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    // MARK: - Segment list

    private var segmentContent: some View {
        let time = playback.currentTime

        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ForEach(editor.result.segments) { segment in
                    if editingSegmentId == segment.id {
                        editableSegmentRow(segment: segment)
                    } else {
                        displaySegmentRow(segment: segment, currentTime: time)
                    }
                    Divider().padding(.leading, 52)
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
            // Timestamp — clickable, plays the whole segment
            Text(formatTimestamp(segment.start))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isCurrent ? AppColors.accent : .secondary)
                .frame(width: 40, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    playback.playSegment(from: segment.start, to: segment.end)
                }

            // Transcript text with karaoke highlight
            wordFlowView(segment: segment, currentTime: currentTime)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Edit button — clear, visible, vertically centered
            Button {
                editingSegmentId = segment.id
                editText = segment.text
                playback.pause()
            } label: {
                Text("Rediger")
                    .font(.system(size: 11, weight: .medium))
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
        .id(segment.id)
    }

    // MARK: - Word flow (karaoke)

    @ViewBuilder
    private func wordFlowView(segment: TranscriptionSegment, currentTime: Double) -> some View {
        if segment.words.isEmpty {
            Text(segment.text.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            WrappingHStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segment.words.enumerated()), id: \.offset) { _, word in
                    let isHighlighted = currentTime >= word.start && currentTime < word.end
                    Text(word.word)
                        .font(.system(size: 13))
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(
                            isHighlighted
                                ? AppColors.accent.opacity(0.25)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                        .onTapGesture {
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
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                TextEditor(text: $editText)
                    .font(.system(size: 13))
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.small)
                            .stroke(AppColors.accent.opacity(0.3), lineWidth: 1)
                    )

                HStack(spacing: AppSpacing.sm) {
                    Button("Lagre") {
                        editor.updateSegment(id: segment.id, text: editText)
                        editingSegmentId = nil
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
        .id(segment.id)
    }

    // MARK: - Audio controls

    private var audioControls: some View {
        HStack(spacing: AppSpacing.lg) {
            // Time display
            Text(formatTimestamp(playback.currentTime))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            // Scrubber
            Slider(value: Binding(
                get: { playback.currentTime },
                set: { playback.seek(to: $0) }
            ), in: 0...max(playback.duration, 0.01))
            .controlSize(.small)

            Text(formatTimestamp(playback.duration))
                .font(.system(size: 12, design: .monospaced))
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

    // MARK: - Tab button

    private func tabButton(label: String, tab: EditorTab) -> some View {
        Button {
            selectedEditorTab = tab
        } label: {
            Text(label)
                .font(.system(size: 13, weight: selectedEditorTab == tab ? .semibold : .regular))
                .foregroundStyle(selectedEditorTab == tab ? .primary : .secondary)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
        }
        .buttonStyle(.plain)
        .background(
            selectedEditorTab == tab
                ? AppColors.accent.opacity(0.08)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.small)
        )
    }

    // MARK: - Collapsible anonymization panel

    private var anonymizationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle header — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    anonymizationExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: anonymizationExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text("Anonymisering")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if anonymizationExpanded {
                AnonymizationSectionView(
                    recordingId: recordingId,
                    isDirty: editor.isDirty
                )
                .padding(.top, AppSpacing.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Helpers

    private var currentSegmentId: Int? {
        let time = playback.currentTime
        return editor.result.segments.last(where: { $0.start <= time && time < $0.end })?.id
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
