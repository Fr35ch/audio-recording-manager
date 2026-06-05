// BonjourConfirmationServer.swift
// Clio
//
// Mac-side Bonjour confirmation server (spec § 9.5).
//
// Clio Mac advertises `_clio-confirm._tcp` on the local network while the
// app is running. After the iOS app transfers a file (via AirDrop or USB),
// it queries this server by original filename. The server responds with the
// current confirmation status based on the RecordingStore.
//
// Wire protocol (plain HTTP, local-network only)
// -----------------------------------------------
//   GET /confirm?filename=<original-filename>
//   → 200 { "confirmed": true,  "recordingId": "<uuid>" }
//   → 200 { "confirmed": false }
//   → 400 if filename param is missing
//
// Security
// --------
// Connections are accepted only from link-local or RFC1918 addresses.
// No credentials are required — the Bonjour query itself is proof of
// local-network presence. The response discloses only confirmation status,
// no audio content.
//
// Lifecycle
// ---------
// Start the server when the app becomes active; stop it on termination.
// `AppDelegate.applicationDidFinishLaunching` should call `start()` after
// `StartupCoordinator.runStartupSequence()` completes.

import Foundation
import Network

// MARK: - Confirmation response

private struct ConfirmationResponse: Encodable {
    let confirmed: Bool
    let recordingId: String?
}

// MARK: - Server

final class BonjourConfirmationServer {

    static let shared = BonjourConfirmationServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "no.nav.clio.confirm-server")

    static let serviceType = "_clio-confirm._tcp"
    static let serviceName = "Clio"

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }

        do {
            let params = NWParameters.tcp
            let nl = try NWListener(using: params)
            nl.service = NWListener.Service(
                name: Self.serviceName,
                type: Self.serviceType,
                domain: "local."
            )

            nl.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    NSLog("[BonjourConfirmationServer] Listener failed: \(error)")
                default:
                    break
                }
            }

            nl.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            nl.start(queue: queue)
            listener = nl
        } catch {
            NSLog("[BonjourConfirmationServer] Failed to create listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let response = self.buildResponse(for: data)
            let httpResponse = self.formatHTTPResponse(body: response)
            connection.send(content: httpResponse, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }

    private func buildResponse(for requestData: Data) -> Data {
        guard let requestString = String(data: requestData, encoding: .utf8),
              let filename = extractFilename(from: requestString) else {
            return httpBody(status: 400, body: "{\"error\":\"missing filename\"}")
        }

        let confirmed = checkConfirmation(for: filename)
        let response = ConfirmationResponse(
            confirmed: confirmed.isConfirmed,
            recordingId: confirmed.recordingId?.uuidString
        )
        let body = (try? JSONEncoder().encode(response)) ?? Data()
        return httpBody(status: 200, body: String(data: body, encoding: .utf8) ?? "{}")
    }

    private func extractFilename(from request: String) -> String? {
        // Parse `GET /confirm?filename=<value> HTTP/1.1`
        guard let queryStart = request.range(of: "filename=") else { return nil }
        let valueStart = request.index(queryStart.upperBound, offsetBy: 0)
        let valueEnd = request[valueStart...].firstIndex(where: { $0 == " " || $0 == "&" || $0 == "\r" || $0 == "\n" }) ?? request.endIndex
        let encoded = String(request[valueStart..<valueEnd])
        return encoded.removingPercentEncoding ?? encoded
    }

    private func checkConfirmation(for filename: String) -> (isConfirmed: Bool, recordingId: UUID?) {
        let recordings = (try? RecordingStore.shared.allRecordings()) ?? []
        for meta in recordings {
            if meta.mobileImport?.originalFilename == filename {
                return (true, meta.id)
            }
        }
        return (false, nil)
    }

    private func httpBody(status: Int, body: String) -> Data {
        let statusLine = status == 200 ? "200 OK" : "\(status) Bad Request"
        let raw = """
        HTTP/1.1 \(statusLine)\r\n\
        Content-Type: application/json\r\n\
        Content-Length: \(body.utf8.count)\r\n\
        Connection: close\r\n\
        \r\n\
        \(body)
        """
        return raw.data(using: .utf8) ?? Data()
    }

    private func formatHTTPResponse(body: Data) -> Data { body }
}
