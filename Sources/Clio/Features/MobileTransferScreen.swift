// MobileTransferScreen.swift
// Clio
//
// UI for importing recordings from Clio Recorder iOS devices.
//
// Flow
// ----
// 1. Screen appears → MobileTransferBrowser starts scanning for `_clio-transfer._tcp`
// 2. User sees a list of discovered iPhone(s)
// 3. User selects a device → recording list is fetched immediately
// 4. Recording list fetched via `MobileTransferClient.listRecordings()`
// 5. User taps a recording row → download + import via `MobileTransferImporter`
// 6. After import, Clio Mac sends `POST /recordings/:id/confirm` to iOS
// 7. Newly imported recording appears in the main library

import SwiftUI

struct MobileTransferScreen: View {

    @StateObject private var browser = MobileTransferBrowser()
    @State private var selectedDeviceId: String?
    @State private var recordings: [MobileRecordingInfo] = []
    @State private var isFetchingList = false
    @State private var importingId: String?
    @State private var importProgress: Double = 0
    @State private var errorMessage: String?
    @State private var disconnectedDeviceName: String?
    @State private var importedIOSIds: Set<String> = []
    @State private var reachabilityTask: Task<Void, Never>?
    // Devices we just disconnected from (e.g. unplugged) but that may still
    // linger in the Bonjour browser until their TTL expires. We must not
    // auto-reopen them until they have actually left and rejoined the network.
    @State private var suppressedDeviceIds: Set<String> = []

    private let importer = MobileTransferImporter()

    private var selectedDevice: DiscoverediOSDevice? {
        browser.discoveredDevices.first { $0.id == selectedDeviceId }
    }

    /// Recording filename with the audio extension stripped for display.
    private func displayName(_ recording: MobileRecordingInfo) -> String {
        (recording.filename as NSString).deletingPathExtension
    }

    private var deviceFoundButNoToken: Bool {
        !browser.discoveredDevices.filter { !suppressedDeviceIds.contains($0.id) }.isEmpty
        && browser.discoveredDevices.filter { !suppressedDeviceIds.contains($0.id) }.allSatisfy { $0.advertisedToken == nil }
    }

    /// USB cable is connected but the Clio app on the phone hasn't advertised yet.
    private var usbConnectedButAppClosed: Bool {
        browser.isUSBTethered && browser.discoveredDevices.isEmpty && selectedDeviceId == nil
    }

    var body: some View {
        Group {
            if selectedDevice != nil {
                recordingList
            } else if let name = disconnectedDeviceName {
                ContentUnavailableView(
                    AppCopy.MobileTransfer.disconnectedTitle,
                    systemImage: "iphone.slash",
                    description: Text(AppCopy.MobileTransfer.disconnectedDescription(name))
                )
            } else if deviceFoundButNoToken || usbConnectedButAppClosed {
                ContentUnavailableView {
                    Label(AppCopy.MobileTransfer.openAppTitle, systemImage: "iphone.gen3")
                } description: {
                    Text(AppCopy.MobileTransfer.openAppDescription(
                        browser.discoveredDevices.first(where: { !suppressedDeviceIds.contains($0.id) })?.name ?? "iPhone"
                    ))
                } actions: {
                    ProgressView()
                }
            } else {
                ContentUnavailableView {
                    Label(AppCopy.MobileTransfer.waitingTitle, systemImage: "iphone.gen3")
                } description: {
                    Text(AppCopy.MobileTransfer.waitingDescription)
                } actions: {
                    if browser.isSearching {
                        ProgressView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Importer fra iPhone")
        .onAppear { browser.startBrowsing() }
        .onDisappear {
            browser.stopBrowsing()
            reachabilityTask?.cancel()
            reachabilityTask = nil
        }
        // Auto-open the library as soon as a phone is detected, and react to
        // unplug / token-arrival without requiring the user to pick from a list.
        .onChange(of: browser.discoveredDevices) { _, devices in
            reconcile(devices)
        }
        .onChange(of: selectedDeviceId) { _, id in
            recordings = []
            importedIOSIds = []
            reachabilityTask?.cancel()
            reachabilityTask = nil
            guard id != nil else { return }
            disconnectedDeviceName = nil
            connectToSelected()
        }
        .alert("Feil", isPresented: Binding(
            get: { errorMessage != nil && !recordings.isEmpty },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Recording list

    private var recordingList: some View {
        Group {
            if isFetchingList {
                ProgressView("Henter opptaksliste...")
            } else if let err = errorMessage, recordings.isEmpty {
                ContentUnavailableView {
                    Label("Kunne ikke hente opptak", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("Prøv igjen") {
                        errorMessage = nil
                        connectToSelected()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if recordings.isEmpty {
                ContentUnavailableView(
                    "Ingen opptak",
                    systemImage: "waveform",
                    description: Text("Det finnes ingen opptak å importere fra denne iPhone.")
                )
            } else {
                List(recordings) { recording in
                    recordingRow(recording)
                }
            }
        }
        .navigationTitle(selectedDevice?.name ?? "Opptak")
    }

    private func recordingRow(_ recording: MobileRecordingInfo) -> some View {
        let alreadyImported = importedIOSIds.contains(recording.id)
        return HStack {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(displayName(recording))
                    .font(.body)
                HStack(spacing: AppSpacing.sm) {
                    if let dur = recording.durationSeconds {
                        Label(formatDuration(dur), systemImage: "clock")
                    }
                    if let size = recording.sizeBytes {
                        Label(formatSize(size), systemImage: "internaldrive")
                    }
                    if recording.isDualChannel == true {
                        Label("RØDE stereo", systemImage: "mic.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if importingId == recording.id {
                if importProgress > 0 {
                    ProgressView(value: importProgress)
                        .frame(width: 60)
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            } else if alreadyImported {
                Label(AppCopy.MobileTransfer.alreadyImported, systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(AppCopy.MobileTransfer.importAction) {
                    Task { await importRecording(recording) }
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .opacity(alreadyImported ? 0.6 : 1)
    }

    // MARK: - Actions

    /// Decides which device (if any) should be open, based on the current
    /// Bonjour results. Auto-opens the first reachable phone and clears the
    /// disconnected state once a previously-unplugged phone truly leaves.
    private func reconcile(_ devices: [DiscoverediOSDevice]) {
        let presentIds = Set(devices.map { $0.id })

        // A suppressed device that has finally left the browser can be reopened
        // if it later returns, so drop it from the suppression set.
        suppressedDeviceIds.formIntersection(presentIds)

        // Selected device vanished from the network (unplug / Wi-Fi lost).
        if let id = selectedDeviceId, !presentIds.contains(id) {
            handleDisconnect(id: id, name: selectedDevice?.name ?? id)
            return
        }

        // Nothing open yet: auto-open the first reachable, non-suppressed phone.
        if selectedDeviceId == nil {
            if let ready = devices.first(where: {
                $0.advertisedToken != nil && !suppressedDeviceIds.contains($0.id)
            }) {
                disconnectedDeviceName = nil
                selectedDeviceId = ready.id
            }
            return
        }

        // Selected device's auth token resolved after selection: fetch now.
        if let device = selectedDevice, device.advertisedToken != nil,
           recordings.isEmpty, !isFetchingList {
            connectToSelected()
        }
    }

    private func connectToSelected() {
        guard let device = selectedDevice else { return }
        Task { await fetchRecordings(for: device) }
        startReachabilityMonitor(for: device)
    }

    /// Actively probes the selected device on a timer. A USB cable pull sends no
    /// Bonjour goodbye packet, so the browser would otherwise keep the stale
    /// device around for ~2 minutes. Polling lets us detect the disconnect and
    /// block imports against a phone that is no longer there.
    private func startReachabilityMonitor(for device: DiscoverediOSDevice) {
        reachabilityTask?.cancel()
        reachabilityTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                guard selectedDeviceId == device.id else { return }
                let client = MobileTransferClient(deviceId: device.id, endpoint: device.endpoint, token: device.advertisedToken)
                let reachable = await client.probeReachable()
                if Task.isCancelled { return }
                if !reachable, selectedDeviceId == device.id {
                    handleDisconnect(id: device.id, name: device.name)
                    return
                }
            }
        }
    }

    private func handleDisconnect(id: String, name: String) {
        reachabilityTask?.cancel()
        reachabilityTask = nil
        suppressedDeviceIds.insert(id)
        disconnectedDeviceName = name
        selectedDeviceId = nil
        recordings = []
        importedIOSIds = []
    }

    private func fetchRecordings(for device: DiscoverediOSDevice) async {
        NSLog("[MobileTransfer] Fetching recordings for \(device.id), endpoint: \(device.endpoint), tokenPresent: \(device.advertisedToken != nil)")
        if let t = device.advertisedToken { NSLog("[MobileTransfer] Token prefix: \(t.prefix(8))") }
        let client = MobileTransferClient(deviceId: device.id, endpoint: device.endpoint, token: device.advertisedToken)
        isFetchingList = true
        defer { isFetchingList = false }
        do {
            recordings = try await client.listRecordings()
            importedIOSIds = loadImportedIOSIds()
        } catch {
            NSLog("[MobileTransfer] Error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Set of iOS recording ids already imported into this Mac's library, used to
    /// mark rows as "already transferred".
    private func loadImportedIOSIds() -> Set<String> {
        guard let all = try? RecordingStore.shared.allRecordings() else { return [] }
        return Set(all.compactMap { $0.mobileImport?.iOSRecordingId })
    }

    private func importRecording(_ recording: MobileRecordingInfo) async {
        guard let device = selectedDevice else { return }
        let client = MobileTransferClient(deviceId: device.id, endpoint: device.endpoint, token: device.advertisedToken)
        importingId = recording.id
        importProgress = 0
        defer {
            importingId = nil
            importProgress = 0
        }

        do {
            let stagingURL = try await client.downloadRecording(id: recording.id) { fraction in
                Task { @MainActor in
                    importProgress = fraction
                }
            }
            let sidecarData = await client.downloadSidecar(id: recording.id)
            _ = try await importer.importRecording(
                stagingURL: stagingURL,
                info: recording,
                deviceName: device.name,
                sidecarData: sidecarData
            )
            try await client.confirmReceipt(id: recording.id)
            importedIOSIds.insert(recording.id)
            RecordingsManager.shared.loadRecordings()
        } catch {
            // A failure mid-import most likely means the cable was pulled. Probe
            // once to confirm, and surface the disconnected state if unreachable.
            let stillReachable = await client.probeReachable()
            if !stillReachable, selectedDeviceId == device.id {
                handleDisconnect(id: device.id, name: device.name)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }
}
