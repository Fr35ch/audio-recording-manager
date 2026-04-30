// VMServiceClient.swift
// AudioRecordingManager / D2A
//
// Thin async REST client for the d2aDecrypter Windows service. Speaks
// the protocol described in `D2A_BRIDGE_INTEGRATION_PLAN.md`:
//
//   GET  /api/health             → HealthResponse
//   POST /api/decrypt            → DecryptResponse  (kicks off a task)
//   GET  /api/status/{taskId}    → DecryptResponse  (poll for progress)
//
// All calls run off the main actor; callers are responsible for hopping
// back to MainActor before mutating @Published state.

import Foundation

// MARK: - Wire types

struct HealthResponse: Codable {
    let status: String
    let sdkVersion: String
    let uptime: Int64
    let activeTasks: Int
}

struct DecryptRequest: Codable {
    let filename: String
    let password: String
    let outputFormat: String   // "m4a" — matches StorageLayout.audioURL
    let taskId: String?
}

struct DecryptResponse: Codable {
    let taskId: String
    let status: String         // "Queued" | "Processing" | "Completed" | "Failed"
    let outputFile: String?
    let progress: Int          // 0–100
    let error: String?
}

// MARK: - Errors

enum D2ABridgeError: LocalizedError {
    case notConfigured
    case serviceUnavailable
    case sharedFolderUnreachable(URL)
    case decryptionFailed(String?)
    case incorrectPassword
    case fileNotFound(URL)
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "D2A-tjenesten er ikke konfigurert. Opprett d2a-config.json."
        case .serviceUnavailable:
            return "Windows VM-tjenesten svarer ikke."
        case .sharedFolderUnreachable(let url):
            return "Delt mappe ikke tilgjengelig: \(url.path)"
        case .decryptionFailed(let reason):
            return "Dekryptering feilet" + (reason.map { ": \($0)" } ?? ".")
        case .incorrectPassword:
            return "Feil passord."
        case .fileNotFound(let url):
            return "Fant ikke filen: \(url.lastPathComponent)"
        case .invalidResponse(let code):
            return "Uventet svar fra VM-tjenesten (HTTP \(code))."
        }
    }
}

// MARK: - Client

final class VMServiceClient {
    private let config: VMServiceConfig
    private let session: URLSession

    init(config: VMServiceConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = config.connectionTimeout
        cfg.timeoutIntervalForResource = config.connectionTimeout * 2
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Health

    func checkHealth() async throws -> HealthResponse {
        let url = config.serviceURL.appendingPathComponent("api/health")
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    // MARK: Decrypt

    func decrypt(file: D2AFile, password: String, taskId: UUID) async throws -> DecryptResponse {
        let url = config.serviceURL.appendingPathComponent("api/decrypt")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = DecryptRequest(
            filename: file.name,
            password: password,
            outputFormat: "m4a",
            taskId: taskId.uuidString
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(DecryptResponse.self, from: data)
    }

    // MARK: Status polling

    func checkStatus(taskId: UUID) async throws -> DecryptResponse {
        let url = config.serviceURL
            .appendingPathComponent("api/status")
            .appendingPathComponent(taskId.uuidString)
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try JSONDecoder().decode(DecryptResponse.self, from: data)
    }

    // MARK: - Helpers

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw D2ABridgeError.serviceUnavailable
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw D2ABridgeError.incorrectPassword
        case 404:
            throw D2ABridgeError.fileNotFound(http.url ?? config.serviceURL)
        case 500..<600:
            throw D2ABridgeError.serviceUnavailable
        default:
            throw D2ABridgeError.invalidResponse(http.statusCode)
        }
    }
}
