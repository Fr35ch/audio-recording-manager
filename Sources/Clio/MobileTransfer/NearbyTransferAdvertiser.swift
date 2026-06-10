// NearbyTransferAdvertiser.swift
// Clio
//
// Advertises the Mac as a Clio receiver via MultipeerConnectivity so that
// Clio Recorder iOS can discover and send recordings directly — without using
// UIActivityViewController or AirDrop's open share sheet.
//
// Only iPhones running Clio Recorder can see this Mac. No third-party apps,
// cloud services, or messaging apps appear in the iOS picker.

import Foundation
import MultipeerConnectivity

final class NearbyTransferAdvertiser: NSObject {
    static let shared = NearbyTransferAdvertiser()
    static let serviceType = "clio-recorder"

    private let myPeerID = MCPeerID(displayName: Host.current().localizedName ?? "Clio Mac")
    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?
    private let importer = MobileTransferImporter()

    /// Posted on the main queue after a recording is successfully received and imported.
    static let didReceiveRecordingNotification = Notification.Name("NearbyTransferAdvertiser.didReceive")

    private override init() {}

    // MARK: - Lifecycle

    func start() {
        guard advertiser == nil else { return }

        let s = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s

        let a = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a

        NSLog("[NearbyTransferAdvertiser] Advertising as '\(myPeerID.displayName)'")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.disconnect()
        session = nil
        NSLog("[NearbyTransferAdvertiser] Stopped")
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension NearbyTransferAdvertiser: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        NSLog("[NearbyTransferAdvertiser] Invitation from \(peerID.displayName) — accepting")
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("[NearbyTransferAdvertiser] Failed to start advertising: \(error)")
    }
}

// MARK: - MCSessionDelegate

extension NearbyTransferAdvertiser: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected: NSLog("[NearbyTransferAdvertiser] \(peerID.displayName) connected")
        case .notConnected: NSLog("[NearbyTransferAdvertiser] \(peerID.displayName) disconnected")
        default: break
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let error {
            NSLog("[NearbyTransferAdvertiser] Receive error for \(resourceName): \(error)")
            return
        }
        guard let localURL else {
            NSLog("[NearbyTransferAdvertiser] No URL for received resource \(resourceName)")
            return
        }

        NSLog("[NearbyTransferAdvertiser] Received '\(resourceName)' from \(peerID.displayName)")

        // MultipeerConnectivity deletes localURL as soon as this delegate method returns.
        // Copy to a stable staging path before dispatching the async import.
        // Use resourceName directly so the display name is clean.
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(resourceName)
        do {
            try FileManager.default.copyItem(at: localURL, to: stagingURL)
        } catch {
            NSLog("[NearbyTransferAdvertiser] Failed to stage '\(resourceName)': \(error)")
            return
        }

        Task {
            do {
                let result = try await importer.importLocalFile(at: stagingURL, deviceName: peerID.displayName)
                NSLog("[NearbyTransferAdvertiser] Imported as recording \(result.recordingId)")
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.didReceiveRecordingNotification,
                        object: nil,
                        userInfo: ["filename": resourceName, "recordingId": result.recordingId]
                    )
                }
            } catch {
                NSLog("[NearbyTransferAdvertiser] Import failed for \(resourceName): \(error)")
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        NSLog("[NearbyTransferAdvertiser] Receiving '\(resourceName)' from \(peerID.displayName) (%.0f%% …)")
    }
}
