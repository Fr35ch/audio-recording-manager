// MobileTransferClient.swift
// Clio
//
// HTTP client for the Clio Recorder iOS transfer server (spec § 9.2).
//
// The iOS app runs an NWListener on a port advertised via Bonjour.
// This client resolves the endpoint, builds a URLSession bound to that
// host, and exposes three operations:
//
//   • listRecordings()        → [MobileRecordingInfo]
//   • downloadRecording(id:)  → local staging URL (WAV)
//   • confirmReceipt(id:)     → Void  (POST /recordings/:id/confirm)
//
// Authentication: every request carries `Authorization: Bearer <token>`.
// A 401 response throws `MobileTransferError.unauthorized` — the caller
// should surface the re-pair flow.

import Foundation
import Network

// MARK: - Wire types

struct MobileRecordingInfo: Codable, Identifiable {
    let id: String
    let filename: String
    let durationSeconds: Double?
    let sizeBytes: Int64?
    let recordedAt: Date?
    let isDualChannel: Bool?       // RODE_DUAL_CHANNEL marker present
}

// MARK: - Errors

enum MobileTransferError: LocalizedError {
    case networkError(underlying: Error)
    case unexpectedStatus(Int)
    case decodingFailed(underlying: Error)
    case noEndpointResolved

    var errorDescription: String? {
        switch self {
        case .networkError(let e):
            return "Nettverksfeil: \(e.localizedDescription)"
        case .unexpectedStatus(let code):
            return "Uventet statuskode \(code) fra iPhone."
        case .decodingFailed(let e):
            return "Kunne ikke lese svar fra iPhone: \(e.localizedDescription)"
        case .noEndpointResolved:
            return "Fant ikke iPhone på nettverket."
        }
    }
}

// MARK: - Client

actor MobileTransferClient {

    private let deviceId: String
    private let endpoint: NWEndpoint
    private var resolvedBaseURL: URL?

    private lazy var decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(deviceId: String, endpoint: NWEndpoint) {
        self.deviceId = deviceId
        self.endpoint = endpoint
    }

    // MARK: - Operations

    func listRecordings() async throws -> [MobileRecordingInfo] {
        let url = try await baseURL().appendingPathComponent("recordings")
        let data = try await perform(request: authenticatedRequest(url: url))
        do {
            return try decoder.decode([MobileRecordingInfo].self, from: data)
        } catch {
            throw MobileTransferError.decodingFailed(underlying: error)
        }
    }

    /// Downloads the WAV to a staging URL and returns it.
    /// Caller is responsible for moving/importing and deleting the staging file.
    func downloadRecording(id: String) async throws -> URL {
        let url = try await baseURL().appendingPathComponent("recordings/\(id)")
        let data = try await perform(request: authenticatedRequest(url: url))

        let stagingURL = StorageLayout.mobileInboxURL
            .appendingPathComponent("\(id).wav")
        try FileManager.default.createDirectory(
            at: StorageLayout.mobileInboxURL,
            withIntermediateDirectories: true
        )
        try data.write(to: stagingURL)
        return stagingURL
    }

    /// Notifies the iOS app that Clio Mac has received and indexed the recording.
    func confirmReceipt(id: String) async throws {
        let url = try await baseURL().appendingPathComponent("recordings/\(id)/confirm")
        var request = authenticatedRequest(url: url)
        request.httpMethod = "POST"
        _ = try await perform(request: request)
    }

    // MARK: - Private helpers

    private func baseURL() async throws -> URL {
        if let cached = resolvedBaseURL { return cached }

        let url: URL
        switch endpoint {
        case .hostPort(let host, let port):
            url = try urlFrom(host: host, port: port)
        case .service:
            url = try await resolveServiceEndpoint()
        default:
            throw MobileTransferError.noEndpointResolved
        }
        resolvedBaseURL = url
        return url
    }

    /// Connects briefly via NWConnection to resolve a .service endpoint to host:port.
    private func resolveServiceEndpoint() async throws -> URL {
        NSLog("[MobileTransferClient] Resolving service endpoint: \(endpoint)")
        return try await withCheckedThrowingContinuation { continuation in
            let conn = NWConnection(to: endpoint, using: .tcp)
            var resumed = false
            conn.stateUpdateHandler = { state in
                NSLog("[MobileTransferClient] Connection state: \(state)")
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let remote = conn.currentPath?.remoteEndpoint,
                       case let .hostPort(host, port) = remote {
                        conn.cancel()
                        let hostString: String
                        switch host {
                        case .ipv4(let a): hostString = "\(a)"
                        case .ipv6(let a): hostString = "[\(a)]"
                        case .name(let n, _): hostString = n
                        @unknown default:
                            continuation.resume(throwing: MobileTransferError.noEndpointResolved)
                            return
                        }
                        if let url = URL(string: "http://\(hostString):\(port.rawValue)") {
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(throwing: MobileTransferError.noEndpointResolved)
                        }
                    } else {
                        conn.cancel()
                        continuation.resume(throwing: MobileTransferError.noEndpointResolved)
                    }
                case .failed(let error):
                    resumed = true
                    conn.cancel()
                    continuation.resume(throwing: MobileTransferError.networkError(underlying: error))
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue(label: "no.nav.clio.endpoint-resolver"))
        }
    }

    private func urlFrom(host: NWEndpoint.Host, port: NWEndpoint.Port) throws -> URL {
        let hostString: String
        switch host {
        case .ipv4(let addr): hostString = "\(addr)"
        case .ipv6(let addr): hostString = "[\(addr)]"
        case .name(let name, _): hostString = name
        @unknown default: throw MobileTransferError.noEndpointResolved
        }
        guard let url = URL(string: "http://\(hostString):\(port.rawValue)") else {
            throw MobileTransferError.noEndpointResolved
        }
        return url
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 30)
        return req
    }

    private func perform(request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MobileTransferError.unexpectedStatus(0)
            }
            switch http.statusCode {
            case 200...299:
                return data
            default:
                throw MobileTransferError.unexpectedStatus(http.statusCode)
            }
        } catch let e as MobileTransferError {
            throw e
        } catch {
            throw MobileTransferError.networkError(underlying: error)
        }
    }
}
