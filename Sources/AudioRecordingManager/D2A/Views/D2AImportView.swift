// D2AImportView.swift
// AudioRecordingManager / D2A
//
// Top-level UI for the D2A import flow. Shows the SD card status,
// any discovered .d2a files, and active import progress. Wires the
// password prompt and `D2ABridgeService` together.
//
// Wiring this into the app navigation is left to the caller — see
// `D2A/README.md` for the AppTab + NavPanel changes needed.

import SwiftUI

struct D2AImportView: View {
    @StateObject private var watcher = SDCardWatcher()
    @StateObject private var bridge = D2ABridgeService()

    @State private var promptedFile: D2AFile?
    @State private var isHealthChecking: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            header

            if let configError = bridge.configError {
                configErrorBanner(message: configError)
            }

            D2AProgressView(
                tasks: bridge.tasks,
                onClearCompleted: { bridge.clearCompleted() }
            )

            if watcher.d2aFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            watcher.startMonitoring()
            Task { await refreshHealth() }
        }
        .onDisappear {
            watcher.stopMonitoring()
        }
        .sheet(item: $promptedFile) { file in
            PasswordPromptView(
                fileName: file.name,
                onSubmit: { password in
                    promptedFile = nil
                    Task { await runImport(file: file, password: password) }
                },
                onCancel: { promptedFile = nil }
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Importer D2A-filer")
                    .font(.title2).bold()
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            healthBadge
            Button {
                Task { await refreshHealth() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isHealthChecking)
            .help("Sjekk VM-tjenesten på nytt")
        }
    }

    private var headerSubtitle: String {
        if let volume = watcher.currentVolume {
            return "SD-kort: \(volume.lastPathComponent)"
        }
        return "Sett inn SD-kort med .d2a-filer for å starte"
    }

    private var healthBadge: some View {
        HStack(spacing: AppSpacing.xs) {
            Circle()
                .fill(bridge.isVMAvailable ? AppColors.success : AppColors.destructive)
                .frame(width: 8, height: 8)
            Text(bridge.isVMAvailable ? "VM tilkoblet" : "VM ikke tilgjengelig")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let sdkVersion = bridge.sdkVersion, bridge.isVMAvailable {
                Text("(SDK \(sdkVersion))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small)
                .fill(.thinMaterial)
        )
    }

    private func configErrorBanner(message: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("D2A-konfigurasjon mangler")
                    .font(.subheadline).bold()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .fill(AppColors.warning.opacity(0.12))
        )
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "sdcard")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Ingen D2A-filer funnet")
                .font(.headline)
            Text("Sett inn et SD-kort fra opptaksenheten – filer vises her automatisk.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List {
            ForEach(watcher.d2aFiles) { file in
                D2AFileRow(file: file) {
                    promptedFile = file
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Actions

    private func refreshHealth() async {
        isHealthChecking = true
        await bridge.checkVMStatus()
        isHealthChecking = false
    }

    private func runImport(file: D2AFile, password: String) async {
        do {
            _ = try await bridge.importD2AFile(file, password: password)
        } catch {
            // Error is captured on the task; the row in D2AProgressView
            // will surface it. Nothing to do here.
        }
    }
}

private struct D2AFileRow: View {
    let file: D2AFile
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(AppColors.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if file.isEncrypted {
                Image(systemName: "lock.fill")
                    .foregroundStyle(AppColors.warning)
                    .help("Kryptert")
            }

            Button("Importer", action: onImport)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, AppSpacing.xs)
    }
}
