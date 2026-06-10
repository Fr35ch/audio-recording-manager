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
// Uses NWBrowser to discover services, then NetService to resolve each
// service's TXT record (NWBrowser metadata does not reliably deliver TXT
// records on macOS — they require an explicit resolve step).

import Foundation
import Network
import Combine
import SystemConfiguration

// MARK: - Discovered Device

struct DiscoverediOSDevice: Identifiable, Equatable, Hashable {
    let id: String          // Bonjour service name — stable per device
    let name: String        // Human-readable display name
    let endpoint: NWEndpoint
    let advertisedToken: String?  // Token from TXT record, used for auth
}

// MARK: - TXT record resolver (NetService-based)

private final class TXTRecordResolver: NSObject, NetServiceDelegate {
    struct Resolved {
        let deviceName: String?
        let token: String?
    }

    private let netService: NetService
    private let completion: (Resolved) -> Void

    init(name: String, completion: @escaping (Resolved) -> Void) {
        self.completion = completion
        self.netService = NetService(domain: "local.", type: "_clio-transfer._tcp", name: name)
        super.init()
        netService.delegate = self
        netService.resolve(withTimeout: 5.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let data = sender.txtRecordData() else {
            completion(Resolved(deviceName: nil, token: nil))
            return
        }
        let dict = NetService.dictionary(fromTXTRecord: data)
        let token = dict["token"].flatMap { String(data: $0, encoding: .utf8) }
        let deviceName = dict["device"].flatMap { String(data: $0, encoding: .utf8) }
        NSLog("[MobileTransferBrowser] Resolved TXT for \(sender.name): device=\(deviceName ?? "nil"), tokenPresent=\(token != nil)")
        completion(Resolved(deviceName: deviceName, token: token))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("[MobileTransferBrowser] TXT resolve failed for \(sender.name): \(errorDict)")
        completion(Resolved(deviceName: nil, token: nil))
    }
}

// MARK: - Browser

@MainActor
final class MobileTransferBrowser: ObservableObject {

    // MARK: Published state

    @Published private(set) var discoveredDevices: [DiscoverediOSDevice] = []
    @Published private(set) var isSearching = false
    /// True when a wired-USB iPhone tether is detected on macOS (wiredEthernet
    /// interface present), regardless of whether the iOS app is open.
    @Published private(set) var isUSBTethered = false

    // MARK: Private

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "no.nav.clio.mobile-transfer-browser")
    private var activeResolvers: [String: TXTRecordResolver] = [:]
    private var pathMonitor: NWPathMonitor?
    private var usbPollTimer: Timer?

    static let serviceType = "_clio-transfer._tcp"

    // MARK: - Lifecycle

    func startBrowsing() {
        guard browser == nil else { return }

        startPathMonitor()

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
            let newDevices: [(serviceName: String, endpoint: NWEndpoint, token: String?)] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var token: String?
                if case let .bonjour(txtRecord) = result.metadata {
                    token = txtRecord.dictionary["token"]
                }
                return (name, result.endpoint, token)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }

                // Preserve any already-resolved display name / token for devices
                // that are still present, so a refresh doesn't flicker back to
                // the raw Bonjour service name.
                let previous = Dictionary(uniqueKeysWithValues: self.discoveredDevices.map { ($0.id, $0) })
                self.discoveredDevices = newDevices.map { item in
                    let existing = previous[item.serviceName]
                    return DiscoverediOSDevice(
                        id: item.serviceName,
                        name: existing?.name ?? item.serviceName,
                        endpoint: item.endpoint,
                        advertisedToken: item.token ?? existing?.advertisedToken
                    )
                }

                // Always resolve via NetService to obtain the human-readable
                // device name (TXT "device") and the auth token (TXT "token"),
                // since NWBrowser does not reliably deliver TXT records on macOS.
                let presentNames = Set(newDevices.map { $0.serviceName })
                self.activeResolvers = self.activeResolvers.filter { presentNames.contains($0.key) }

                for item in newDevices {
                    let needsName = (previous[item.serviceName]?.name ?? item.serviceName) == item.serviceName
                    let needsToken = (item.token ?? previous[item.serviceName]?.advertisedToken) == nil
                    guard needsName || needsToken else { continue }
                    guard self.activeResolvers[item.serviceName] == nil else { continue }

                    let serviceName = item.serviceName
                    let endpoint = item.endpoint
                    self.activeResolvers[serviceName] = TXTRecordResolver(name: serviceName) { [weak self] resolved in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.activeResolvers.removeValue(forKey: serviceName)
                            self.discoveredDevices = self.discoveredDevices.map { device in
                                guard device.id == serviceName else { return device }
                                return DiscoverediOSDevice(
                                    id: serviceName,
                                    name: resolved.deviceName ?? device.name,
                                    endpoint: endpoint,
                                    advertisedToken: resolved.token ?? device.advertisedToken
                                )
                            }
                        }
                    }
                }
            }
        }

        nb.start(queue: queue)
        browser = nb
        isSearching = true
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        activeResolvers.removeAll()
        isSearching = false
        discoveredDevices = []
        pathMonitor?.cancel()
        pathMonitor = nil
        usbPollTimer?.invalidate()
        usbPollTimer = nil
        isUSBTethered = false
    }

    // MARK: - USB detection

    /// Returns true when an iPhone USB interface is present.
    /// Uses SCNetworkInterfaceCopyAll which lists all network-capable
    /// interfaces regardless of routing, unlike NWPathMonitor which
    /// only surfaces interfaces on the current best path.
    nonisolated private func iPhoneUSBInterfacePresent() -> Bool {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return false }
        return all.contains { iface in
            let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? ?? ""
            return name.localizedCaseInsensitiveContains("iphone")
        }
    }

    // MARK: - USB path monitor

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }

        // Immediately check current state using SCNetworkInterfaceCopyAll,
        // which includes all network-capable interfaces regardless of routing.
        // NWPathMonitor.availableInterfaces only covers the current best path,
        // so it misses the iPhone USB interface when Wi-Fi is primary.
        isUSBTethered = iPhoneUSBInterfacePresent()

        // Poll every second so plug/unplug events are reflected promptly.
        usbPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let tethered = self.iPhoneUSBInterfacePresent()
            Task { @MainActor [weak self] in
                self?.isUSBTethered = tethered
            }
        }

        // Keep NWPathMonitor running alongside for faster detection of changes
        // (the timer provides the reliable initial + periodic fallback).
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let tethered = path.availableInterfaces.contains { $0.type == .wiredEthernet }
            guard tethered else { return }  // only act on positive signals; timer handles removal
            Task { @MainActor [weak self] in
                self?.isUSBTethered = true
            }
        }
        monitor.start(queue: DispatchQueue(label: "no.nav.clio.path-monitor"))
        pathMonitor = monitor
    }
}
