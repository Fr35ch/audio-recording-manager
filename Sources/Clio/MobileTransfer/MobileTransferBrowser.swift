// MobileTransferBrowser.swift
// Clio
//
// Discovers Clio Recorder iOS instances on the local network via Bonjour.
// The iOS app advertises `_clio-transfer._tcp` while foregrounded and
// connected via USB or Wi-Fi. This browser surfaces reachable devices to
// the MobileTransferScreen for user-initiated import.
//
// Network model
// -------------
// Uses Network.framework NWBrowser. Results are delivered on a background
// queue and marshalled to @MainActor for UI consumption. The browser is
// started lazily on first access to the MobileTransferScreen and stopped
// when the screen disappears.

import Foundation
import Network
import Combine

// MARK: - Discovered Device

struct DiscoverediOSDevice: Identifiable, Equatable, Hashable {
    let id: String          // Bonjour service name — stable per device
    let name: String        // Human-readable display name
    let endpoint: NWEndpoint
}

// MARK: - Browser

@MainActor
final class MobileTransferBrowser: ObservableObject {

    // MARK: Published state

    @Published private(set) var discoveredDevices: [DiscoverediOSDevice] = []
    @Published private(set) var isSearching = false

    // MARK: Private

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "no.nav.clio.mobile-transfer-browser")

    static let serviceType = "_clio-transfer._tcp"

    // MARK: - Lifecycle

    func startBrowsing() {
        guard browser == nil else { return }

        let params = NWParameters()
        params.includePeerToPeer = false

        let nb = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: params)

        nb.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed, .cancelled:
                    self?.isSearching = false
                    self?.browser = nil
                default:
                    break
                }
            }
        }

        nb.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap { result -> DiscoverediOSDevice? in
                guard case let .bonjour(txtRecord) = result.metadata else { return nil }
                // Use the service name from the endpoint directly
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                _ = txtRecord
                return DiscoverediOSDevice(
                    id: name,
                    name: name,
                    endpoint: result.endpoint
                )
            }
            Task { @MainActor [weak self] in
                self?.discoveredDevices = devices
            }
        }

        nb.start(queue: queue)
        browser = nb
        isSearching = true
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
        discoveredDevices = []
    }
}
