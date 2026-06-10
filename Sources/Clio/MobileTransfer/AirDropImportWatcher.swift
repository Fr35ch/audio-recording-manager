// AirDropImportWatcher.swift
// Clio
//
// Watches the user's Downloads folder for recordings AirDropped from Clio
// Recorder iOS and imports them into the RecordingStore automatically.
//
// Why a folder watcher
// --------------------
// AirDrop delivers files to ~/Downloads with no programmatic hook. To make the
// "AirDrop from iPhone → appears in Clio Mac" flow work without manual import,
// we monitor the folder via a DispatchSource and react to new audio files.
//
// Matching
// --------
// Only files following the Clio naming convention `<title>_yyyyMMdd_HHmmss.ext`
// (ext ∈ {wav, m4a}) are considered, so unrelated downloads are ignored. Each
// candidate is debounced and checked for size stability (AirDrop writes
// incrementally) before import. Imported/seen filenames are tracked to avoid
// double processing.
//
// Security
// --------
// No network access. Reads only from ~/Downloads and writes into the Clio
// data root via MobileTransferImporter. Honors the no-cloud policy. The
// original AirDropped file is deleted from ~/Downloads immediately after a
// successful import so sensitive interview audio never lingers there.

import Foundation

/// Thread-safety: all mutable state (`processed`, `pendingSizes`, `source`,
/// `fileDescriptor`) is accessed only on `queue`, so the type is safe to treat
/// as Sendable for use inside the import `Task`.
final class AirDropImportWatcher: @unchecked Sendable {

    static let shared = AirDropImportWatcher()

    /// Posted (on the main queue) after a file is successfully imported.
    /// userInfo["filename"] = original filename.
    static let didImportNotification = Notification.Name("AirDropImportWatcher.didImport")

    private let importer = MobileTransferImporter()
    private let queue = DispatchQueue(label: "no.nav.clio.airdrop-watcher", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var debounceWorkItem: DispatchWorkItem?

    /// Filenames already imported or currently in flight — avoids re-importing
    /// the same AirDropped file on every folder event.
    private var processed: Set<String> = []
    /// Last observed size per candidate, used to detect when a write completes.
    private var pendingSizes: [String: Int64] = [:]

    private static let candidatePattern = #".+_\d{8}_\d{6}\.(wav|m4a)$"#

    private var watchedFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.beginWatching()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    // MARK: - Watching

    private func beginWatching() {
        guard source == nil else { return }

        let path = watchedFolder.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[AirDropImportWatcher] Could not open \(path) for monitoring")
            return
        }
        fileDescriptor = fd

        // Pre-seed processed set with existing files so we only react to NEW
        // arrivals, not the entire Downloads backlog.
        for url in currentCandidates() {
            processed.insert(url.lastPathComponent)
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.scheduleScan()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 { close(fd) }
            self?.fileDescriptor = -1
        }
        source = src
        src.resume()
        NSLog("[AirDropImportWatcher] Watching \(path) for AirDropped recordings")
    }

    private func scheduleScan() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scanForNewRecordings()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scanForNewRecordings() {
        for url in currentCandidates() {
            let name = url.lastPathComponent
            guard !processed.contains(name) else { continue }

            // Wait for the file to stop growing before importing.
            let size = fileSize(of: url)
            if pendingSizes[name] != size {
                pendingSizes[name] = size
                scheduleScan()
                continue
            }
            pendingSizes.removeValue(forKey: name)
            processed.insert(name)
            importCandidate(at: url)
        }
    }

    private func importCandidate(at url: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.importer.importLocalFile(at: url, deviceName: "AirDrop")
                NSLog("[AirDropImportWatcher] Imported \(url.lastPathComponent)")

                // Privacy: the AirDropped file contains sensitive interview
                // audio and must not linger in ~/Downloads. Remove it now that
                // it has been copied into the Clio data root.
                try? FileManager.default.removeItem(at: url)

                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.didImportNotification,
                        object: nil,
                        userInfo: ["filename": url.lastPathComponent]
                    )
                }
            } catch {
                // Allow a later retry if import failed (e.g. partial file).
                let name = url.lastPathComponent
                self.queue.async { [weak self] in self?.processed.remove(name) }
                NSLog("[AirDropImportWatcher] Import failed for \(name): \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func currentCandidates() -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: watchedFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.filter { url in
            url.lastPathComponent.range(
                of: Self.candidatePattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private func fileSize(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    }
}
