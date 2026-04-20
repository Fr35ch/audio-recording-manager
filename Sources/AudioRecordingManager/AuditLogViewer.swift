// AuditLogViewer.swift
// AudioRecordingManager
//
// Hidden diagnostic view showing audit log + file change log.
// Accessed via ⌘L + password "Quark".

import SwiftUI

struct AuditLogViewer: View {
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
        changeLines = loadTail(url: StorageLayout.auditRoot.appendingPathComponent("file-changes.log"))
    }

    private func loadTail(url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let all = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if all.count <= lineLimit { return all }
        return Array(all.suffix(lineLimit))
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
