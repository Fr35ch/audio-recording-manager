// MobileTransferScreen.swift
// Clio
//
// UI for importing recordings from a paired Clio Recorder iOS device.
//
// Flow
// ----
// 1. Screen appears → MobileTransferBrowser starts scanning for `_clio-transfer._tcp`
// 2. User sees a list of discovered iPhone(s)
// 3. User selects a device → pairing check
//    a. If unpaired: show token, instruct user to enter it in iOS app, then tap "Bekrefter"
//    b. If paired: proceed to recording list
// 4. Recording list fetched via `MobileTransferClient.listRecordings()`
// 5. User taps a recording row → download + import via `MobileTransferImporter`
// 6. After import, Clio Mac sends `POST /recordings/:id/confirm` to iOS
// 7. Newly imported recording appears in the main library

import SwiftUI

struct MobileTransferScreen: View {

    @StateObject private var browser = MobileTransferBrowser()
    @StateObject private var pairing = MobilePairingService()
    @State private var selectedDevice: DiscoverediOSDevice?
    @State private var recordings: [MobileRecordingInfo] = []
    @State private var isFetchingList = false
    @State private var importingId: String?
    @State private var errorMessage: String?
    @State private var showPairingSheet = false
    @State private var enteredToken: String = ""

    private let importer = MobileTransferImporter()

    var body: some View {
        HStack(spacing: 0) {
            // Device sidebar
            VStack(spacing: 0) {
                List(browser.discoveredDevices, selection: $selectedDevice) { device in
                    Label(device.name, systemImage: "iphone")
                        .tag(device)
                }
                .overlay {
                    if browser.isSearching && browser.discoveredDevices.isEmpty {
                        VStack(spacing: AppSpacing.md) {
                            ProgressView()
                            Text("Søker etter iPhone...")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    } else if !browser.isSearching && browser.discoveredDevices.isEmpty {
                        ContentUnavailableView(
                            "Ingen iPhone funnet",
                            systemImage: "iphone.slash",
                            description: Text("Åpne Clio Recorder og koble til via USB eller Wi-Fi.")
                        )
                    }
                }
                .onChange(of: selectedDevice) { _, device in
                    recordings = []
                    guard let device else { return }
                    connectTo(device: device)
                }
            }
            .frame(width: 220)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .trailing) {
                Divider()
            }

            // Detail area
            Group {
                if selectedDevice != nil {
                    recordingList
                } else {
                    ContentUnavailableView(
                        "Velg en iPhone",
                        systemImage: "iphone",
                        description: Text("Koble til iPhone via USB eller samme Wi-Fi-nettverk, og åpne Clio Recorder.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Importer fra iPhone")
        .onAppear { browser.startBrowsing() }
        .onDisappear { browser.stopBrowsing() }
        .sheet(isPresented: $showPairingSheet) { pairingSheet }
        .alert("Feil", isPresented: Binding(
            get: { errorMessage != nil },
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
        HStack {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(recording.filename)
                    .font(.body)
                HStack(spacing: AppSpacing.sm) {
                    if let dur = recording.durationSeconds {
                        Label(formatDuration(dur), systemImage: "clock")
                    }
                    if let size = recording.sizeBytes {
                        Label(formatSize(size), systemImage: "internaldrive")
                    }
                    if recording.isDualChannel {
                        Label("RØDE stereo", systemImage: "mic.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if importingId == recording.id {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button("Importer") {
                    Task { await importRecording(recording) }
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    // MARK: - Pairing sheet

    private var pairingSheet: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Par med iPhone")
                .font(.title2.bold())

            Text("Åpne Clio Recorder på iPhone og kopier koden som vises der:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            TextField("Lim inn kode fra iPhone", text: $enteredToken)
                .font(.system(.title3, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit { confirmIfValid() }

            HStack {
                Button("Avbryt") {
                    enteredToken = ""
                    showPairingSheet = false
                }
                .buttonStyle(HoverButtonStyle())
                Button("Bekrefter") { confirmIfValid() }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(enteredToken.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 360)
    }

    // MARK: - Actions

    private func connectTo(device: DiscoverediOSDevice) {
        // Use token from TXT record if available, otherwise fall back to stored/manual token
        if let advertisedToken = device.advertisedToken {
            pairing.confirmPairing(deviceId: device.id, token: advertisedToken)
            Task { await fetchRecordings(for: device) }
        } else if pairing.token(for: device.id) != nil {
            Task { await fetchRecordings(for: device) }
        } else {
            enteredToken = ""
            showPairingSheet = true
        }
    }

    private func confirmIfValid() {
        let token = enteredToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, let device = selectedDevice else { return }
        enteredToken = ""
        showPairingSheet = false
        pairing.confirmPairing(deviceId: device.id, token: token)
        Task { await fetchRecordings(for: device) }
    }

    private func fetchRecordings(for device: DiscoverediOSDevice) async {
        guard let token = pairing.token(for: device.id) else { return }
        let client = MobileTransferClient(deviceId: device.id, token: token, endpoint: device.endpoint)
        isFetchingList = true
        defer { isFetchingList = false }
        do {
            recordings = try await client.listRecordings()
        } catch MobileTransferError.unauthorized {
            pairing.revoke(deviceId: device.id)
            errorMessage = "Autentisering feilet. Par enheten på nytt."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importRecording(_ recording: MobileRecordingInfo) async {
        guard let device = selectedDevice,
              let token = pairing.token(for: device.id) else { return }

        let client = MobileTransferClient(deviceId: device.id, token: token, endpoint: device.endpoint)
        importingId = recording.id
        defer { importingId = nil }

        do {
            let stagingURL = try await client.downloadRecording(id: recording.id)
            _ = try await importer.importRecording(
                stagingURL: stagingURL,
                info: recording,
                deviceName: device.name
            )
            try await client.confirmReceipt(id: recording.id)
            // Remove from list — it's now in the library
            recordings.removeAll { $0.id == recording.id }
        } catch {
            errorMessage = error.localizedDescription
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
