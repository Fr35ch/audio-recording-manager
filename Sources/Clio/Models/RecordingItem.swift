import Foundation

// MARK: - Recording Item Model
struct RecordingItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let filename: String
    let path: String
    let date: Date
    let size: Int64
    let duration: TimeInterval

    /// Audio file URL via StorageLayout (single source of truth).
    var audioURL: URL { StorageLayout.audioURL(id: id) }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
