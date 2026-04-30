// AuditLogViewer.swift
// AudioRecordingManager
//
// Hidden diagnostic view showing audit log + file change log.
// Accessed via ⌘L + password "Quark".

import SwiftUI

struct AuditLogViewer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var auditLines: [String] = []
    @State private var changeLines: [String] = []
    @State private var selectedTab = 0
    @State private var lineLimit = 500

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ARM Loggvisning")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(selectedTab == 0 ? auditLines.count : changeLines.count) linjer (siste \(lineLimit))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Oppdater") { loadLogs() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Lukk") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Picker("", selection: $selectedTab) {
                Text("Revisjonslogg").tag(0)
                Text("Filendringer").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            let lines = selectedTab == 0 ? auditLines : changeLines

            if lines.isEmpty {
                ContentUnavailableView(
                    selectedTab == 0 ? "Ingen revisjonslogg" : "Ingen filendringer",
                    systemImage: "doc.text",
                    description: Text(selectedTab == 0
                        ? "Revisjonsloggen er tom."
                        : "Kjør scripts/file-monitor.sh --init først.")
                )
            } else {
                List {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 800, height: 600)
        .onAppear { loadLogs() }
    }

    private func loadLogs() {
        auditLines = loadTail(url: StorageLayout.currentMonthAuditLog)
        changeLines = loadTail(
            url: StorageLayout.auditRoot.appendingPathComponent("file-changes.log"),
            filter: filterAudioAndText
        )
    }

    private func loadTail(url: URL, filter: ((String) -> Bool)? = nil) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if let filter { lines = lines.filter(filter) }
        if lines.count <= lineLimit { return lines }
        return Array(lines.suffix(lineLimit))
    }

    private func filterAudioAndText(_ line: String) -> Bool {
        // Keep separator lines, CHECK lines, and INIT lines for context
        if line.contains("────") || line.contains("CHECK") || line.contains("INIT") { return true }
        // Keep lines about audio and text files only
        let audioExts = [".m4a", ".mp3", ".wav", ".aac", ".ds2"]
        let textExts = [".txt"]
        let allExts = audioExts + textExts
        return allExts.contains { line.contains($0) }
    }
}

// MARK: - Password gate

struct PasswordGateView: View {
    @Binding var isPresented: Bool
    @State private var password = ""
    @State private var unlocked = false
    @FocusState private var focused: Bool

    private let correctPassword = "Quark"

    var body: some View {
        if unlocked {
            AuditLogViewer()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Loggvisning")
                    .font(.system(size: 15, weight: .semibold))

                SecureField("Passord", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($focused)
                    .onSubmit { tryUnlock() }

                HStack(spacing: 12) {
                    Button("Avbryt") { isPresented = false }
                        .buttonStyle(.bordered)
                    Button("Lås opp") { tryUnlock() }
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty)
                }
            }
            .padding(32)
            .frame(width: 320, height: 240)
            .onAppear { focused = true }
        }
    }

    private func tryUnlock() {
        if password == correctPassword {
            unlocked = true
        } else {
            password = ""
        }
    }
}
