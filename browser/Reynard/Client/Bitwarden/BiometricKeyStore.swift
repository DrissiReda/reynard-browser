//
//  BiometricKeyStore.swift
//  Reynard
//
//  Stores the Bitwarden user key in the iOS Keychain behind a Face ID gate.
//  The item uses `.biometryCurrentSet`, so enrolling a new face / removing
//  biometrics invalidates it and forces re-enrollment with the master password.
//

import Foundation
import LocalAuthentication
import Security

enum BiometricKeyStoreError: Error {
    case unavailable          // no biometrics enrolled / not capable
    case cancelled            // user cancelled or auth failed
    case notFound
    case keychain(OSStatus)
}

struct BiometricKeyStore {
    static let service = "com.minh-ton.Reynard.bitwarden.userkey"
    private var service: String { Self.service }

    /// Account ids with a stored key, without prompting Face ID (diagnostics).
    static func enrolledAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var out: CFTypeRef?
        SecItemCopyMatching(query as CFDictionary, &out)
        let items = (out as? [[String: Any]]) ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Biometrics present and usable right now.
    static var isAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// Store `key` for `account` (the Bitwarden user id). Replaces any existing item.
    /// No biometric prompt on write — the gate is on read.
    func store(_ key: Data, account: String) throws {
        guard let ac = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil
        ) else { throw BiometricKeyStoreError.unavailable }

        try? delete(account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessControl as String: ac,
            // Write must not trigger the biometric UI; supply an evaluated-free context.
            kSecUseAuthenticationContext as String: { let c = LAContext(); c.interactionNotAllowed = true; return c }(),
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw BiometricKeyStoreError.keychain(status) }
    }

    /// Retrieve the key for `account`, prompting Face ID with `reason`.
    // nonisolated: the SecItem Face ID prompt blocks its thread; must run off the main actor.
    nonisolated func load(account: String, reason: String) throws -> Data {
        let ctx = LAContext()
        ctx.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: ctx,
            kSecUseOperationPrompt as String: reason,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { throw BiometricKeyStoreError.notFound }
            return data
        case errSecItemNotFound:
            throw BiometricKeyStoreError.notFound
        case errSecUserCanceled, errSecAuthFailed:
            throw BiometricKeyStoreError.cancelled
        default:
            throw BiometricKeyStoreError.keychain(status)
        }
    }

    func has(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail, // don't prompt, just probe
            kSecReturnData as String: false,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BiometricKeyStoreError.keychain(status)
        }
    }
}
