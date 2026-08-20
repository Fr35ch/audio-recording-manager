// BibliotekView.swift
// Clio
//
// "Bibliotek" — the canonical library view of every recording in the
// app. Replaces the card-row RecordingsListColumn in the recordings
// tab's column 2. Implements US-R13–R18:
//
//   - Title + summary stats (N opptak · M transkribert · K analysert)
//   - Sort menu (newest / oldest / name / expiry soonest)
//   - Filter chip row with counts
//   - Conditional expiry-warning banner
//   - Table with NAVN / VARIGH. / DATO / TRANSKR. / AVIDENT. / ANALYSE
//     / TEAMS / SLETTES status chips
//   - Play button on each row that previews audio without opening
//     column 3
//   - Selecting a row drives column 3 (existing pattern)
//
// Status derivation lives entirely in `RecordingStatusBundle` —
// definitions of "Klar for Teams", "Venter avid.", expiry thresholds,
// etc. live in one place there.

import AppKit
import SwiftUI

struct BibliotekView: View {
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var transcriptionRunner = TranscriptionRunner.shared
    @Binding var selectedRecording: RecordingItem?
    /// `true` when column 3 is visible (a recording is selected); the
    /// table compresses to play + name + date + a single urgency chip.
    /// `false` when column 3 is hidden; the full status pipeline shows.
    let isCompact: Bool

    @State private var activeFilter: BibliotekFilter = .alle
    @State private var bundles: [RecordingStatusBundle] = []

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            filterChipsRow
            expiryBanner
            Divider()
            if filteredBundles.isEmpty {
                emptyState
                    .frame(maxHeight: .infinity)
            } else {
                tableHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredBundles) { bundle in
                            rowView(bundle)
                            Divider().padding(.leading, AppSpacing.lg)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { reload() }
        .onChange(of: recordingsManager.recordings) { _, _ in reload() }
        .onChange(of: transcriptionRunner.inFlight) { _, _ in reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bibliotek")
                    .font(AppFont.screenTitle)
                Text(summaryLine)
                    .clioSectionLabel()
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.lg)
        .padding(.bottom, AppSpacing.md)
    }

    private var summaryLine: String {
        let total = bundles.count
        let transcribed = bundles.filter { $0.isTranscribed }.count
        return "\(total) opptak · \(transcribed) transkribert"
    }

    // MARK: - Filter chips

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(BibliotekFilter.allCases) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.md)
        }
    }

    private func filterChip(_ filter: BibliotekFilter) -> some View {
        let isActive = activeFilter == filter
        let n = bundles.filter { filter.matches($0) }.count
        let tone = isActive ? filter.tone : ChipTone.neutral

        return Button {
            activeFilter = filter
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(StatusChipView.foreground(tone))
                    .frame(width: 6, height: 6)
                Text("\(filter.label) (\(n))")
                    .font(isActive ? AppFont.chipLabelActive : AppFont.chipLabel)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(StatusChipView.background(tone, active: isActive))
            )
            .overlay(
                Capsule().stroke(
                    StatusChipView.foreground(tone).opacity(isActive ? 0 : 0.3),
                    lineWidth: 1)
            )
            .foregroundStyle(isActive ? StatusChipView.foreground(tone) : .primary)
        }
        .buttonStyle(.plain)
        .hoverCursor()
    }

    // MARK: - Expiry banner (US-R18)

    @ViewBuilder
    private var expiryBanner: some View {
        let urgent = bundles.filter {
            $0.daysUntilExpiry <= RecordingStatusBundle.bannerThresholdDays
        }
        if !urgent.isEmpty {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                Text("\(urgent.count) opptak slettes om under \(RecordingStatusBundle.bannerThresholdDays) dager — og transkripsjonene er ikke avidentifisert ennå. Fullfør avid. og last opp til Teams før fristen.")
                    .font(AppFont.tableMetaCell)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    activeFilter = .utløperSnart
                } label: {
                    HStack(spacing: 4) {
                        Text("Vis dem")
                        Image(systemName: "arrow.right")
                    }
                    .font(AppFont.chipLabelActive)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverCursor()
            }
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(AppColors.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .stroke(AppColors.warning.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.md)
        }
    }

    // MARK: - Table

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("").frame(width: 32, alignment: .leading)
            columnHeader("NAVN", width: nil, alignment: .leading)
            if !isCompact {
                columnHeader("VARIGH.", width: 70, alignment: .leading)
            }
            columnHeader("DATO", width: 130, alignment: .center)
            columnHeader("TRANSKRIBERING", width: 150, alignment: .leading)
            if !isCompact {
                columnHeader("AVIDENT.", width: 110, alignment: .leading)
                columnHeader("ANALYSE", width: 100, alignment: .leading)
                columnHeader("TEAMS", width: 70, alignment: .leading)
            }
            columnHeader("SLETTES", width: 70, alignment: .center)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    private func columnHeader(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        Group {
            if let width {
                Text(text)
                    .font(.clioLabel)
                    .tracking(ClioTracking.label())
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: alignment)
            } else {
                Text(text)
                    .font(.clioLabel)
                    .tracking(ClioTracking.label())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: alignment)
            }
        }
    }

    private func rowView(_ bundle: RecordingStatusBundle) -> some View {
        BibliotekRow(
            bundle: bundle,
            isSelected: selectedRecording?.id == bundle.id,
            isCompact: isCompact,
            audioPlayer: audioPlayer,
            onSelect: {
                selectedRecording = recordingsManager.recordings.first { $0.id == bundle.id }
            },
            onDoubleClick: {
                guard bundle.isTranscribed else { return }
                openWindow(id: "transcript-editor", value: bundle.id)
            },
            onDelete: {
                if let item = recordingsManager.recordings.first(where: { $0.id == bundle.id }) {
                    recordingsManager.deleteRecording(item)
                    if selectedRecording?.id == bundle.id { selectedRecording = nil }
                }
            },
            transcribeButton: { transcribeActionButton(for: bundle) }
        )
    }

    // MARK: - Transcription action button

    /// Every pill click selects the row first so the right-pane player
    /// follows whatever the user just acted on (start a transcription,
    /// open the editor, or cancel an in-flight run). Without this, a
    /// click on the pill would start work on a recording that the user
    /// can't see in the detail pane — confusing, and led to users
    /// pressing Transkriber twice from two different surfaces.
    private func selectRow(_ id: UUID) {
        selectedRecording = recordingsManager.recordings.first { $0.id == id }
    }

    @ViewBuilder
    private func transcribeActionButton(for bundle: RecordingStatusBundle) -> some View {
        let isRunning = transcriptionRunner.inFlight.contains(bundle.id)

        if isRunning {
            RunningPill(
                startTime: transcriptionRunner.startTimes[bundle.id],
                audioDuration: transcriptionRunner.audioDurations[bundle.id]
            ) {
                selectRow(bundle.id)
                transcriptionRunner.cancel(recordingId: bundle.id)
            }
            .help("Avbryt transkripsjon")
        } else if bundle.isTranscribed {
            Button("Åpne") {
                selectRow(bundle.id)
                openWindow(id: "transcript-editor", value: bundle.id)
            }
            .buttonStyle(PillButtonStyle(variant: .secondary))
            .help("Åpne transkripsjon i editor")
        } else {
            Button("Transkriber") {
                transcriptionRunner.start(recordingId: bundle.id, audioDuration: bundle.durationSeconds)
            }
            .buttonStyle(PillButtonStyle(variant: .primary))
            .help("Start transkripsjon")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Spacer()
            Image(systemName: "tray")
                .font(AppFont.iconEmptyState)
                .foregroundStyle(.secondary.opacity(0.6))
            if activeFilter != .alle {
                Text("Ingen opptak i dette filteret")
                    .font(AppFont.bodyMedium)
                Button("Vis alle") { activeFilter = .alle }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverCursor()
            } else {
                Text("Ingen opptak ennå")
                    .font(AppFont.bodyMedium)
                Text("Bruk «Ta opp lyd» for å starte ditt første opptak.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived data

    private var filteredBundles: [RecordingStatusBundle] {
        bundles
            .filter { activeFilter.matches($0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Reload

    private func reload() {
        let metas = RecordingStore.shared.loadAll()

        bundles = metas.map { meta in
            RecordingStatusBundle.make(meta: meta)
        }
    }

}

// MARK: - Bibliotek Row

private struct BibliotekRow<TranscribeButton: View>: View {
    let bundle: RecordingStatusBundle
    let isSelected: Bool
    let isCompact: Bool
    @ObservedObject var audioPlayer: AudioPlayer
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let transcribeButton: () -> TranscribeButton

    @State private var isHovered = false
    @State private var isPlayHovered = false

    private var playIconName: String {
        let url = StorageLayout.audioURL(id: bundle.id)
        let isCurrent = audioPlayer.currentPlayingURL == url
        return (isCurrent && audioPlayer.isPlaying) ? "pause.circle.fill" : "play.circle.fill"
    }

    private func togglePlay() {
        let url = StorageLayout.audioURL(id: bundle.id)
        if audioPlayer.currentPlayingURL == url {
            audioPlayer.togglePlayPause()
        } else {
            audioPlayer.play(url: url)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Play button
            Button { togglePlay() } label: {
                Image(systemName: playIconName)
                    .font(AppFont.iconRow)
                    .foregroundStyle(isPlayHovered ? AppColors.accent : AppColors.accent.opacity(0.7))
                    .scaleEffect(isPlayHovered ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: 0.12), value: isPlayHovered)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Spill av")
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isPlayHovered = true
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                case .ended:
                    isPlayHovered = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }

            Text(bundle.displayName)
                .font(AppFont.tableCell)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isCompact {
                Text(formatDuration(bundle.durationSeconds))
                    .font(AppFont.tableMonoCell)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 70, alignment: .leading)
            }

            Text(formatDate(bundle.createdAt))
                .font(AppFont.tableMetaCell)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .center)

            transcribeButton()
                .frame(width: 150, alignment: .leading)

            if !isCompact {
                StatusChipView(chip: bundle.avident).frame(width: 110, alignment: .leading)
                StatusChipView(chip: bundle.teams).frame(width: 70, alignment: .leading)
            }
            Text(bundle.slettes.label)
                .font(AppFont.tableMetaCell)
                .foregroundStyle(StatusChipView.foreground(bundle.slettes.tone))
                .frame(width: 70, alignment: .center)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                AppColors.accent.opacity(0.12)
            } else if isHovered {
                AppColors.accent.opacity(0.06)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick() })
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .onHover { hovering in
            isHovered = hovering
            if !hovering { DispatchQueue.main.async { NSCursor.arrow.set() } }
        }
        .help(bundle.isTranscribed ? "Dobbeltklikk for å åpne i editor" : bundle.displayName)
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: {
                Label("Slett opptak", systemImage: "trash")
            }
        }
    }

    private func formatDuration(_ seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "—" }
        let total = Int(s)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, mins, secs)
            : String(format: "%d:%02d", mins, secs)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Placeholder bundle for SwiftUI previews / silence-warning helper

private extension RecordingStatusBundle {
    static var placeholder: RecordingStatusBundle {
        RecordingStatusBundle(
            id: UUID(),
            displayName: "",
            createdAt: Date(),
            durationSeconds: nil,
            transcript: StatusChip(label: "—", tone: .neutral),
            avident: StatusChip(label: "—", tone: .neutral),
            teams: StatusChip(label: "—", tone: .neutral),
            slettes: StatusChip(label: "—", tone: .neutral),
            isTranscribed: false,
            venterAvident: false,
            klarForTeams: false,
            utløperSnart: false,
            daysUntilExpiry: 0
        )
    }
}
