//
//  BitwardenNativeHost.swift
//  Reynard
//
//  Reynard plays the role of the Bitwarden desktop app: the native-messaging
//  host the official Bitwarden extension talks to for "unlock with biometrics".
//  The extension's connectNative("com.8bit.bitwarden") is routed by GeckoView
//  into an AddonPort (see AddonMessaging.swift); this class answers the
//  Bitwarden native-messaging protocol on that port and gates the vault user
//  key behind Face ID (BiometricKeyStore).
//
//  Protocol: setupEncryption (RSA-OAEP-SHA1 wrap of a 64-byte shared secret),
//  then an EncString type-2 channel. The user key is obtained once by
//  BitwardenAuthClient enrollment and stored keyed by the Bitwarden account id.
//

import Foundation
import GeckoView

@MainActor
final class BitwardenNativeHost: AddonMessageDelegate, AddonPortDelegate {
    static let extensionID = "{446900e4-71c2-419f-a6a7-df9c091e268b}"
    static let nativeApp = "com.8bit.bitwarden"

    private let store = BiometricKeyStore()
    private var ports: [ObjectIdentifier: AddonPort] = [:]
    /// Shared AES+HMAC secret per extension appId (survives across its messages).
    private var secrets: [String: BitwardenSymmetricKey] = [:]

    /// appIds seen per port, so their secrets can be dropped on disconnect.
    private var portAppIds: [ObjectIdentifier: Set<String>] = [:]
    private var runtimeRegistered = false
    /// Face ID in flight per userId; concurrent requests share one prompt.
    private var unlockWaiters: [String: [(Bool, String?) -> Void]] = [:]

    func register(for session: GeckoSession) {
        session.setAddonMessageDelegate(self, extensionID: Self.extensionID, nativeApp: Self.nativeApp)
        // Bitwarden's biometric handshake runs in its background service worker,
        // which has no tab session: connectNative dispatches on the runtime
        // dispatcher, so we must register there too.
        guard !runtimeRegistered else { return }
        runtimeRegistered = true
        AddonRuntime.shared.setRuntimeAddonMessageDelegate(self, extensionID: Self.extensionID, nativeApp: Self.nativeApp)
    }

    // MARK: - Port lifecycle

    func addonPortDidConnect(_ port: AddonPort) {
        guard port.sender.extensionID == Self.extensionID else { return }
        port.delegate = self
        ports[ObjectIdentifier(port)] = port
        // The extension treats the channel as ready only after "connected".
        port.postMessage(["command": "connected"])
    }

    func addonPortDidDisconnect(_ port: AddonPort) {
        let id = ObjectIdentifier(port)
        ports.removeValue(forKey: id)
        for appId in portAppIds.removeValue(forKey: id) ?? [] { secrets.removeValue(forKey: appId) }
    }

    // MARK: - Inbound

    func addonPort(_ port: AddonPort, didReceive message: Any) {
        guard let outer = message as? [String: Any] else { return }
        let appId = outer["appId"] as? String ?? ""
        let inner = outer["message"]
        portAppIds[ObjectIdentifier(port), default: []].insert(appId)

        // Handshake is plaintext.
        if let m = inner as? [String: Any], (m["command"] as? String) == "setupEncryption" {
            handleSetupEncryption(m, appId: appId, port: port)
            return
        }
        // Everything else is an EncString.
        guard let key = secrets[appId], let enc = BitwardenEncString(wire: inner),
              let pt = enc.decrypt(key: key),
              let payload = (try? JSONSerialization.jsonObject(with: pt)) as? [String: Any] else {
            // No session secret / undecryptable: ask the extension to re-handshake.
            port.postMessage(["command": "invalidateEncryption", "appId": appId])
            return
        }
        handleCommand(payload, appId: appId, key: key, port: port)
    }

    // MARK: - Handshake

    private func handleSetupEncryption(_ m: [String: Any], appId: String, port: AddonPort) {
        guard let pub = m["publicKey"] as? String else { return }
        let (key, raw) = BitwardenSymmetricKey.random()
        guard let wrapped = BitwardenRSA.encryptOAEPSHA1(raw, spkiPublicKeyB64: pub) else {
            port.postMessage(["command": "invalidateEncryption", "appId": appId])
            return
        }
        secrets[appId] = key
        port.postMessage([
            "appId": appId,
            "command": "setupEncryption",
            "messageId": -1,                       // marks a new desktop client
            "sharedSecret": wrapped.base64EncodedString(),
        ])
    }

    // MARK: - Commands

    private func handleCommand(_ payload: [String: Any], appId: String, key: BitwardenSymmetricKey, port: AddonPort) {
        let command = payload["command"] as? String ?? ""
        let messageId = payload["messageId"]
        let userId = payload["userId"] as? String

        switch command {
        case "getBiometricsStatus", "getBiometricsStatusForUser":
            let status = biometricsStatus(userId: userId)
            reply(["command": command, "messageId": messageId, "response": status],
                  appId: appId, key: key, port: port)

        case "authenticateWithBiometrics":
            unlock(userId: userId, reason: "Authenticate with Face ID") { ok, _ in
                self.reply(["command": command, "messageId": messageId, "response": ok],
                           appId: appId, key: key, port: port)
            }

        case "unlockWithBiometricsForUser", "biometricUnlock": // legacy name accepted
            unlock(userId: userId, reason: "Unlock your Bitwarden vault") { ok, userKeyB64 in
                var r: [String: Any] = ["command": command, "messageId": messageId as Any, "response": ok]
                if ok, let userKeyB64 { r["userKeyB64"] = userKeyB64 }
                self.reply(r, appId: appId, key: key, port: port)
            }

        default:
            break // ignore unknown commands
        }
    }

    /// 0 Available, 1 UnlockNeeded, 2 HardwareUnavailable, 7 NotEnabledLocally.
    private func biometricsStatus(userId: String?) -> Int {
        guard BiometricKeyStore.isAvailable else { return 2 }
        guard let userId, store.has(account: userId) else { return 7 }
        return 0
    }

    /// Runs Face ID off the main actor (SecItemCopyMatching blocks on the prompt).
    private func unlock(userId: String?, reason: String, completion: @escaping (Bool, String?) -> Void) {
        guard let userId else { completion(false, nil); return }
        if unlockWaiters[userId] != nil {
            unlockWaiters[userId]?.append(completion)
            return
        }
        unlockWaiters[userId] = [completion]
        let store = self.store
        Task.detached {
            let key = try? store.load(account: userId, reason: reason)
            let b64 = key?.base64EncodedString()
            await MainActor.run {
                let waiters = self.unlockWaiters.removeValue(forKey: userId) ?? []
                for w in waiters { w(b64 != nil, b64) }
            }
        }
    }

    // MARK: - Outbound (encrypted)

    private func reply(_ plaintext: [String: Any], appId: String, key: BitwardenSymmetricKey, port: AddonPort) {
        var body = plaintext
        body["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let enc = BitwardenEncString.encrypt(data, key: key)
        port.postMessage([
            "appId": appId,
            "messageId": plaintext["messageId"] ?? NSNull(),
            "message": enc.wireObject,
        ])
    }
}
