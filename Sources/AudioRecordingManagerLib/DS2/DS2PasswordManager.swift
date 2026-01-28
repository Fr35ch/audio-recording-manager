//
//  DS2PasswordManager.swift
//  AudioRecordingManager
//
//  Secure password storage using macOS Keychain
//

import Foundation
import Security

/// Secure password manager using macOS Keychain
final class DS2PasswordManager: DS2PasswordManagerProtocol {
    static let shared = DS2PasswordManager()

    private let service = "com.audiorecordingmanager.ds2"
    private let accessGroup: String? = nil  // Can be set for app groups

    private init() {}

    // MARK: - DS2PasswordManagerProtocol

    func storePassword(_ password: String, for fileURL: URL) throws {
        let account = generateAccount(for: fileURL)

        // Delete existing entry if present
        try? deletePassword(for: fileURL)

        guard let passwordData = password.data(using: .utf8) else {
            throw DS2Error.unknown(NSError(
                domain: "DS2PasswordManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode password"]
            ))
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw DS2Error.unknown(NSError(
                domain: "DS2PasswordManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to store password: \(status)"]
            ))
        }

        print("🔐 Stored password for: \(fileURL.lastPathComponent)")
    }

    func retrievePassword(for fileURL: URL) throws -> String? {
        let account = generateAccount(for: fileURL)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return nil
            }
            throw DS2Error.unknown(NSError(
                domain: "DS2PasswordManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve password: \(status)"]
            ))
        }

        guard let passwordData = result as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            throw DS2Error.unknown(NSError(
                domain: "DS2PasswordManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode password"]
            ))
        }

        print("🔓 Retrieved password for: \(fileURL.lastPathComponent)")
        return password
    }

    func deletePassword(for fileURL: URL) throws {
        let account = generateAccount(for: fileURL)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DS2Error.unknown(NSError(
                domain: "DS2PasswordManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to delete password: \(status)"]
            ))
        }

        print("🗑️ Deleted password for: \(fileURL.lastPathComponent)")
    }

    func hasPassword(for fileURL: URL) -> Bool {
        let account = generateAccount(for: fileURL)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func clearAllPasswords() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DS2Error.unknown(NSError(
                domain: "DS2PasswordManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to clear passwords: \(status)"]
            ))
        }

        print("🧹 Cleared all DS2 passwords from Keychain")
    }

    // MARK: - Private Helpers

    /// Generate unique account identifier from file URL
    private func generateAccount(for fileURL: URL) -> String {
        // Use file path as account identifier
        // This ensures each file has a unique password entry
        return fileURL.path
    }
}
