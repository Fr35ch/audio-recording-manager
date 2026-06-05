// MobilePairingService.swift
// Clio
//
// Manages the Bearer token used to authenticate requests from Clio Mac
// to the Clio Recorder iOS HTTP server (spec § 9.2).
//
// First pairing
// -------------
// 1. User opens MobileTransferScreen and taps "Pair".
// 2. Clio Mac generates a cryptographically random token and displays it.
// 3. User enters the same token in Clio Recorder on iPhone.
// 4. From this point on, every HTTP request to the iOS server includes
//    `Authorization: Bearer <token>`. The iOS app rejects mismatched tokens.
// 5. After a successful `GET /recordings` response (HTTP 200), the token is
//    persisted in the Mac Keychain under the device's service name.
//
// Token rotation
// --------------
// The user can revoke pairing from either side, which generates a new token
// on the iOS side. The Mac detects a 401 and prompts to re-pair.

import Foundation
import Security

// MARK: - Pairing state

enum PairingState: Equatable {
    case unpaired
    case paired(deviceId: String)
}

// MARK: - Service

@MainActor
final class MobilePairingService: ObservableObject {

    @Published private(set) var state: PairingState = .unpaired

    // MARK: - Token management

    /// Called after the user pastes the token shown by the iOS app.
    /// Persists the token in Keychain and marks the device as paired.
    func confirmPairing(deviceId: String, token: String) {
        saveToken(token, for: deviceId)
        state = .paired(deviceId: deviceId)
    }

    /// Returns the stored Bearer token for a device, if paired.
    func token(for deviceId: String) -> String? {
        loadToken(for: deviceId)
    }

    /// Revokes a device pairing and deletes its token from Keychain.
    func revoke(deviceId: String) {
        deleteToken(for: deviceId)
        state = .unpaired
    }

    // MARK: - Keychain helpers

    private func keychainService(for deviceId: String) -> String {
        "no.nav.clio.mobile-transfer.\(deviceId)"
    }

    private func saveToken(_ token: String, for deviceId: String) {
        guard let data = token.data(using: .utf8) else { return }
        let service = keychainService(for: deviceId)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "bearer-token",
            kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadToken(for deviceId: String) -> String? {
        let service = keychainService(for: deviceId)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "bearer-token",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    private func deleteToken(for deviceId: String) {
        let service = keychainService(for: deviceId)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "bearer-token"
        ]
        SecItemDelete(query as CFDictionary)
    }
}
