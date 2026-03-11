import SwiftUI

// MARK: - App Tab

enum AppTab {
    case record
    case recordings
    case transcripts
}

// MARK: - Transcripts View (Transkripsjoner tab)

struct TranscriptsView: View {
    @ObservedObject var transcriptManager: TranscriptManager
    @StateObject private var recordingsManager = RecordingsManager.shared
    @Binding var selectedTab: AppTab

    @State private var selectedTranscript: TranscriptItem? = nil

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // Sidebar: transcript list
            List(transcriptManager.transcripts, selection: $selectedTranscript) { transcript in
                TranscriptRowView(
                    transcript: transcript,
                    hasAnonymization: hasAnonymization(for: transcript)
                )
                .tag(transcript)
                .listRowSeparator(.visible)
            }
            .listStyle(.plain)
            .navigationTitle("Transkripsjoner")
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // Detail: selected transcript or empty state
            if let transcript = selectedTranscript {
                TranscriptDetailPanel(
                    transcript: transcript,
                    matchingRecording: matchingRecording(for: transcript),
                    onSwitchToRecordings: { selectedTab = .recordings }
                )
                .id(transcript.path)
            } else {
                ContentUnavailableView(
                    "Velg en transkripsjon",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Klikk på en fil til venstre for å vise innhold og kjøre anonymisering.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Helpers

    private func matchingRecording(for transcript: TranscriptItem) -> RecordingItem? {
        recordingsManager.recordings.first {
            URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent
                == transcript.stem
        }
    }

    private func hasAnonymization(for transcript: TranscriptItem) -> Bool {
        RecordingMetadataManager.shared.load(for: transcript.path)?.anonymizedTranscript != nil
    }
}

// MARK: - Transcript Row View

private struct TranscriptRowView: View {
    let transcript: TranscriptItem
    let hasAnonymization: Bool
    @State private var isHovering = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(transcript.filename)
                    .font(.body)
                Text(transcript.formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: hasAnonymization ? "shield.lefthalf.filled" : "doc.text")
                .font(.title3)
                .foregroundStyle(hasAnonymization ? .green : .blue)
        }
        .listRowBackground(
            isHovering ? Color(nsColor: .controlAccentColor).opacity(0.1) : Color.clear
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Transcript Detail Panel

/// Right panel for the Transkripsjoner tab.
private struct TranscriptDetailPanel: View {
    let transcript: TranscriptItem
    let matchingRecording: RecordingItem?
    let onSwitchToRecordings: () -> Void

    @State private var originalText: String = ""
    @State private var loadError: String? = nil
    @State private var metadata: RecordingMetadata? = nil
    @State private var anonymizationState: TranscriptAnonymizationState = .notStarted
    @State private var showAnonymizationModal = false
    @State private var showOriginal: Bool = true
    @State private var anonymizationTask: Task<Void, Never>? = nil
    @State private var startTime: Date? = nil

    private var stableId: String {
        URL(fileURLWithPath: transcript.path).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        Form {
            if let err = loadError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                anonymizationSection
                textSection
                if let rec = matchingRecording {
                    matchingRecordingSection(rec)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(transcript.filename)
        .navigationSubtitle(subtitleText)
        .onAppear { loadData() }
        .onDisappear { anonymizationTask?.cancel() }
        .sheet(isPresented: $showAnonymizationModal) {
            AnonymizationModal(isPresented: $showAnonymizationModal, onConfirm: startAnonymization)
        }
    }

    private var subtitleText: String {
        var parts: [String] = [transcript.formattedDate, transcript.formattedSize]
        if !originalText.isEmpty {
            let wordCount = originalText
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            parts.append("\(wordCount) ord")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sections

    private var textSection: some View {
        Section("Transkripsjon") {
            if case .completed = anonymizationState {
                Picker("Visning", selection: $showOriginal) {
                    Text("Original").tag(true)
                    Text("Anonymisert").tag(false)
                }
                .pickerStyle(.segmented)
            }

            let isAnonymized = !showOriginal && metadata?.anonymizedTranscript != nil
            let displayText: String = {
                if isAnonymized, let anon = metadata?.anonymizedTranscript {
                    return anon
                }
                return originalText
            }()

            Text(displayText.isEmpty ? "(tom fil)" : displayText)
                .textSelection(.enabled)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var anonymizationSection: some View {
        Section("Anonymisering") {
            switch anonymizationState {
            case .notStarted:
                Button {
                    showAnonymizationModal = true
                } label: {
                    Label("Anonymiser transkripsjon", systemImage: "shield.lefthalf.filled")
                }
                .disabled(originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("Hva som fjernes:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(whatIsRemoved, id: \.self) { item in
                    Label(item, systemImage: "minus.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .inProgress:
                HStack {
                    ProgressView()
                    Text("Anonymiserer...")
                }
                Text("NLP-modellen lastes ved første kjøring – dette kan ta noen sekunder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Avbryt", action: cancelAnonymization)

            case .completed(let date, let stats):
                Label {
                    Text("Anonymisert \(date.formatted(date: .abbreviated, time: .shortened))")
                } icon: {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }

                if !stats.isEmpty {
                    Text(statsSummary(stats))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showAnonymizationModal = true
                } label: {
                    Label("Kjør på nytt", systemImage: "arrow.counterclockwise")
                }

            case .failed(let error):
                Label {
                    Text("Feil ved anonymisering")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Text(error.errorDescription ?? "Ukjent feil")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showAnonymizationModal = true
                } label: {
                    Label("Prøv igjen", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func matchingRecordingSection(_ recording: RecordingItem) -> some View {
        Section("Tilknyttet lydopptak") {
            Label {
                VStack(alignment: .leading) {
                    Text(recording.filename)
                    Text("\(recording.formattedDuration) · \(recording.formattedDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "waveform")
                    .foregroundStyle(.blue)
            }

            Button("Åpne lydopptak") {
                onSwitchToRecordings()
            }
        }
    }

    // MARK: Constants

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

    // MARK: Load data

    private func loadData() {
        // Read original text from .txt file (the file IS the original — we never modify it)
        do {
            originalText = try String(contentsOfFile: transcript.path, encoding: .utf8)
        } catch {
            loadError = error.localizedDescription
            return
        }

        // Load metadata for anonymization state
        let loaded = RecordingMetadataManager.shared.load(for: transcript.path)
        metadata = loaded
        if let loaded = loaded, let date = loaded.anonymizationDate {
            anonymizationState = .completed(date: date, stats: loaded.anonymizationStats ?? [:])
        }
    }

    // MARK: Actions

    private func startAnonymization() {
        let text = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        anonymizationTask?.cancel()
        anonymizationState = .inProgress
        startTime = Date()

        anonymizationTask = Task { @MainActor in
            do {
                let result = try await AnonymizationService.shared.anonymize(transcript: text)
                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(startTime ?? Date()) * 1000
                RecordingMetadataManager.shared.applyAnonymizationResult(
                    result, for: transcript.path)

                AuditLogger.shared.logAnonymization(
                    recordingId: stableId,
                    stats: result.stats,
                    processingTimeMs: elapsed,
                    outcome: .success
                )

                metadata = RecordingMetadataManager.shared.load(for: transcript.path)
                anonymizationState = .completed(date: Date(), stats: result.stats)
                showOriginal = false

            } catch let error as AnonymizationError {
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(startTime ?? Date()) * 1000
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

// MARK: - Transcript anonymization state (private to this file)

private enum TranscriptAnonymizationState {
    case notStarted
    case inProgress
    case completed(date: Date, stats: [String: Int])
    case failed(AnonymizationError)
}
