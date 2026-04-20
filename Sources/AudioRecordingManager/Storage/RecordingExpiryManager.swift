// RecordingExpiryManager.swift
// AudioRecordingManager
//
// 30-day local retention enforcement. Runs on every app launch to:
//   1. Delete recordings that have expired (createdAt + 30 days ≤ now)
//   2. Emit audit warnings for recordings approaching expiry
//
// The expiry clock is `createdAt` — never reset by any action.
// Deletion is not blocked by upload state.
//
// See: PHASE_0_TASKS.md §0F, US-FM-17, FILE_MANAGEMENT_AND_TEAMS_SYNC.md §Local lifecycle

import Foundation

// MARK: - Warning state

enum ExpiryWarningState: Equatable {
    case none
    case sevenDays(daysRemaining: Int)
    case oneDay
    case expired
}

// MARK: - Manager

final class RecordingExpiryManager {
    static let shared = RecordingExpiryManager()

    static let retentionDays = 30
    static let firstWarningDay = 23

    private let calendar = Calendar.current

    private init() {}

    // MARK: - Public API

    func expiryDate(for meta: RecordingMeta) -> Date {
        calendar.date(byAdding: .day, value: Self.retentionDays, to: meta.createdAt) ?? meta.createdAt
    }

    func daysRemaining(for meta: RecordingMeta) -> Int {
        let expiry = expiryDate(for: meta)
        let components = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: expiry))
        return components.day ?? 0
    }

    func warningState(for meta: RecordingMeta) -> ExpiryWarningState {
        let remaining = daysRemaining(for: meta)
        if remaining <= 0 { return .expired }
        if remaining == 1 { return .oneDay }
        if remaining <= (Self.retentionDays - Self.firstWarningDay) { return .sevenDays(daysRemaining: remaining) }
        return .none
    }

    // MARK: - Launch check

    func checkAndExpire() {
        let allRecordings = RecordingStore.shared.loadAll()
        let today = calendar.startOfDay(for: Date())

        for meta in allRecordings {
            let state = warningState(for: meta)

            switch state {
            case .expired:
                deleteExpired(meta: meta)

            case .sevenDays, .oneDay:
                emitWarningIfNeeded(meta: meta, today: today)

            case .none:
                break
            }
        }
    }

    // MARK: - Private

    private func deleteExpired(meta: RecordingMeta) {
        let uploadStatus = meta.upload.audio.status.rawValue

        AuditLogger.shared.logExpired(
            recordingId: meta.id,
            createdAt: meta.createdAt,
            deletedAt: Date(),
            uploadStatus: uploadStatus
        )

        do {
            try RecordingStore.shared.delete(id: meta.id)
            print("🗑️ Expired recording deleted: \(meta.displayName) (created \(meta.createdAt))")
        } catch {
            print("❌ Failed to delete expired recording \(meta.id): \(error)")
        }
    }

    private func emitWarningIfNeeded(meta: RecordingMeta, today: Date) {
        if let lastWarning = meta.lastWarningDate,
           calendar.isDate(lastWarning, inSameDayAs: today) {
            return
        }

        let remaining = daysRemaining(for: meta)
        AuditLogger.shared.logExpiryWarning(recordingId: meta.id, daysRemaining: remaining)

        _ = try? RecordingStore.shared.updateMeta(id: meta.id) { m in
            m.lastWarningDate = today
        }
    }
}
