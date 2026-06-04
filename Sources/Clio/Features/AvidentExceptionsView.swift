// AvidentExceptionsView.swift
// Clio
//
// Sheet for managing the global de-identification (avidentifisering)
// exception list. Entries are plain strings that the post-processor
// uses to un-redact spans the upstream NER model flagged but the
// researcher wants preserved (e.g. "NAV", organisation names, study
// terms that aren't personal data).
//
// The list lives in `AppState.avidentExceptions` and applies across
// every recording globally — opening this sheet from any segment row
// edits the same shared list.
//
// Matching is case-insensitive exact equality on the redacted span;
// see `AnonymizationResult.applying(exceptions:to:)` for the post-
// processing logic.

import SwiftUI

struct AvidentExceptionsView: View {
    @Binding var isPresented: Bool

    @State private var exceptions: [String] = []
    @State private var newEntry: String = ""
    @State private var saveError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unntak fra avidentifisering")
                    .font(.system(size: 15, weight: .semibold))
                Text("Ord eller navn som ikke skal fjernes, selv om modellen markerer dem. Gjelder alle opptak.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Lukk") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
        }
        .padding(AppSpacing.lg)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            addRow
            Divider()
            list
        }
    }

    private var addRow: some View {
        HStack(spacing: AppSpacing.sm) {
            TextField("Legg til ord (f.eks. «NAV»)", text: $newEntry)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add() }
            Button("Legg til", action: add)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(AppSpacing.lg)
    }

    private var list: some View {
        Group {
            if exceptions.isEmpty {
                ContentUnavailableView(
                    "Ingen unntak",
                    systemImage: "checkmark.shield",
                    description: Text("Legg til ord som skal beholdes — for eksempel organisasjonsnavn som «NAV» eller paragrafer som ofte misforstås som personnavn.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(exceptions.enumerated()), id: \.offset) { (index, entry) in
                        HStack {
                            Text(entry)
                                .font(.system(size: 13))
                            Spacer()
                            Button {
                                remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(AppColors.destructive)
                            }
                            .buttonStyle(.plain)
                            .help("Fjern «\(entry)»")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppColors.destructive)
                } else {
                    Text("\(exceptions.count) \(exceptions.count == 1 ? "unntak" : "unntak") lagret")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Endringene gjelder neste gang en avidentifisering kjøres.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(action: restoreDefaults) {
                    Label("Tilbakestill til anbefalte unntak", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Legger til den kuraterte listen av norske ord som v0.5.0-modellen ofte feiltagger som personnavn. Eksisterende egne unntak beholdes.")
                .hoverCursor()
                Spacer()
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
    }

    // MARK: - Actions

    private func load() {
        exceptions = AppStateStore.load().avidentExceptions
    }

    private func add() {
        let trimmed = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedup case-insensitively so the list stays clean.
        if exceptions.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            newEntry = ""
            return
        }
        exceptions.append(trimmed)
        newEntry = ""
        persist()
    }

    private func remove(at index: Int) {
        guard exceptions.indices.contains(index) else { return }
        exceptions.remove(at: index)
        persist()
    }

    /// Re-merges the curated defaults into the current list. Existing
    /// entries are preserved (deduped case-insensitively), so the
    /// researcher's customisations survive a "restore defaults" click.
    private func restoreDefaults() {
        exceptions = DefaultAvidentExceptions.mergedWith(exceptions)
        persist()
    }

    private func persist() {
        do {
            try AppStateStore.update { $0.avidentExceptions = exceptions }
            saveError = nil
        } catch {
            saveError = "Kunne ikke lagre: \(error.localizedDescription)"
        }
    }
}
