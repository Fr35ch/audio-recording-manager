// SDCardWatcher.swift
// AudioRecordingManager / D2A
//
// Wraps the existing `SDCardManager` singleton (defined in main.swift)
// and exposes a D2A-specific view of any mounted volume: just the
// `.d2a` files, surfaced as `D2AFile` value types.
//
// This file deliberately does NOT set up its own DiskArbitration
// session — there is already one in `SDCardManager`, and running two
// of them registers duplicate callbacks for every mount.

import Combine
import Foundation

@MainActor
final class SDCardWatcher: ObservableObject {

    @Published private(set) var d2aFiles: [D2AFile] = []
    @Published private(set) var currentVolume: URL?
    @Published private(set) var isScanning = false

    private var cancellables = Set<AnyCancellable>()
    private let manager = SDCardManager.shared

    func startMonitoring() {
        manager.$sdCardPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                self?.handleVolumeChange(path: path)
            }
            .store(in: &cancellables)

        // Initial scan in case a card was already mounted at launch.
        handleVolumeChange(path: manager.sdCardPath)
    }

    func stopMonitoring() {
        cancellables.removeAll()
        d2aFiles = []
        currentVolume = nil
    }

    func rescan() {
        handleVolumeChange(path: manager.sdCardPath)
    }

    // MARK: - Private

    private func handleVolumeChange(path: String?) {
        guard let path else {
            currentVolume = nil
            d2aFiles = []
            return
        }
        let volumeURL = URL(fileURLWithPath: path)
        currentVolume = volumeURL
        scan(volumeURL)
    }

    private func scan(_ root: URL) {
        isScanning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = Self.enumerateD2AFiles(in: root)
            await self?.applyScanResults(found)
        }
    }

    private func applyScanResults(_ found: [D2AFile]) {
        d2aFiles = found
        isScanning = false
    }

    nonisolated private static func enumerateD2AFiles(in root: URL) -> [D2AFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [D2AFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "d2a" else { continue }
            results.append(D2AFile(url: url))
        }
        results.sort { $0.createdAt > $1.createdAt }
        return results
    }
}
