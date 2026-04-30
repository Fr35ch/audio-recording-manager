// D2AProgressView.swift
// AudioRecordingManager / D2A
//
// Compact progress strip rendered above the file list while one or more
// D2A imports are in flight. Shown for queued, copying, decrypting and
// importing tasks; hidden once everything terminal has been cleared.

import SwiftUI

struct D2AProgressView: View {
    let tasks: [DecryptionTask]
    let onClearCompleted: () -> Void

    private var inFlight: [DecryptionTask] {
        tasks.filter { !$0.isTerminal }
    }

    private var hasCompleted: Bool {
        tasks.contains { $0.isTerminal }
    }

    var body: some View {
        if tasks.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(tasks) { task in
                    D2ATaskRow(task: task)
                }

                if hasCompleted {
                    HStack {
                        Spacer()
                        Button("Fjern fullførte", action: onClearCompleted)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(.thinMaterial)
            )
        }
    }
}

private struct D2ATaskRow: View {
    let task: DecryptionTask

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.file.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = task.error, task.status == .failed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AppColors.destructive)
                        .lineLimit(2)
                }
            }

            Spacer()

            if !task.isTerminal {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 100)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .queued, .copying, .decrypting, .importing:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColors.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.destructive)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var statusLabel: String {
        switch task.status {
        case .queued: return "I kø"
        case .copying: return "Kopierer til VM"
        case .decrypting: return "Dekrypterer (\(Int(task.progress * 100)) %)"
        case .importing: return "Importerer til opptaksliste"
        case .completed: return "Fullført"
        case .failed: return "Feilet"
        case .cancelled: return "Avbrutt"
        }
    }
}
