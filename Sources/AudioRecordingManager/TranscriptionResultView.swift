import SwiftUI

// MARK: - Speaker colors

private let speakerColors: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .cyan,
]

private func colorForSpeaker(_ speaker: String) -> Color {
    // Hash the speaker label to a stable index
    let index = abs(speaker.hashValue) % speakerColors.count
    return speakerColors[index]
}

// MARK: - Export format

private enum ExportFormat: String, CaseIterable {
    case markdown = "Markdown"
    case srt = "SRT"
}

// MARK: - Segment row

private struct SegmentRow: View {
    let segment: TranscriptionSegment
    let showSpeakers: Bool

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timestamp + speaker badge
            VStack(alignment: .leading, spacing: 3) {
                Text(formatTimestamp(segment.start))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                if showSpeakers {
                    Text(shortSpeakerLabel(segment.speaker))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            colorForSpeaker(segment.speaker).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .foregroundStyle(colorForSpeaker(segment.speaker))
                }
            }
            .frame(width: 68, alignment: .leading)

            // Transcript text
            Text(segment.text.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Copy button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Kopier segment")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            colorForSpeaker(segment.speaker).opacity(0.04),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func shortSpeakerLabel(_ speaker: String) -> String {
        // "SPEAKER_00" → "T1", "SPEAKER_01" → "T2", etc.
        if let numStr = speaker.split(separator: "_").last, let num = Int(numStr) {
            return "T\(num + 1)"
        }
        return speaker
    }
}

// MARK: - Main Result View

struct TranscriptionResultView: View {
    let result: TranscriptionResult

    @State private var searchText = ""
    @State private var showSpeakers = true
    @State private var exportFormat: ExportFormat = .markdown

    private var filteredSegments: [TranscriptionSegment] {
        guard !searchText.isEmpty else { return result.segments }
        return result.segments.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            segmentList
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Søk i transkripsjon...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 200)

            Spacer()

            // Speaker toggle
            Toggle(isOn: $showSpeakers) {
                Text("Talere")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .help("Vis taleretiketter på hvert segment")

            // Export button
            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.rawValue) {
                        exportAs(format)
                    }
                }
            } label: {
                Label("Eksporter", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Eksporter transkripsjon")

            // Copy all button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullPlainText, forType: .string)
            } label: {
                Label("Kopier alt", systemImage: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .help("Kopier hele transkripsjonen til utklippstavlen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Segment list

    private var segmentList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if filteredSegments.isEmpty {
                    Text("Ingen segmenter samsvarte med søket.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(filteredSegments, id: \.id) { segment in
                        SegmentRow(segment: segment, showSpeakers: showSpeakers)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: Export helpers

    private var fullPlainText: String {
        result.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n\n")
    }

    private func exportAs(_ format: ExportFormat) {
        let content: String
        let ext: String
        switch format {
        case .markdown:
            content = markdownExport()
            ext = "md"
        case .srt:
            content = srtExport()
            ext = "srt"
        }

        let panel = NSSavePanel()
        panel.title = "Eksporter transkripsjon"
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "transkripsjon.\(ext)"
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func markdownExport() -> String {
        var lines = ["# Transkripsjon\n"]
        for segment in result.segments {
            let ts = formatTimestamp(segment.start)
            let speaker = shortSpeakerLabel(segment.speaker)
            lines.append("**[\(ts)] \(speaker):** \(segment.text.trimmingCharacters(in: .whitespaces))\n")
        }
        return lines.joined(separator: "\n")
    }

    private func srtExport() -> String {
        var lines: [String] = []
        for (i, segment) in result.segments.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(srtTimestamp(segment.start)) --> \(srtTimestamp(segment.end))")
            lines.append(segment.text.trimmingCharacters(in: .whitespaces))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func srtTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func shortSpeakerLabel(_ speaker: String) -> String {
        if let numStr = speaker.split(separator: "_").last, let num = Int(numStr) {
            return "Taler \(num + 1)"
        }
        return speaker
    }
}
