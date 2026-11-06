//
//  BitwardenAuthClient.swift
//  Reynard
//
//  One-time enrollment: log into Bitwarden/vaultwarden with the master password,
//  derive the account's user key, and hand it to BiometricKeyStore. After this
//  the extension unlocks via Face ID and the master password is never stored.
//
//  Crypto (PBKDF2 accounts, client_kdf_type=0):
//    masterKey        = PBKDF2-SHA256(password, salt=email.lowercased(), iters, 32)
//    masterPwdHash    = base64(PBKDF2-SHA256(masterKey, salt=password, 1, 32))   // server auth
//    stretched        = HKDF-Expand(masterKey,"enc",32) || HKDF-Expand(masterKey,"mac",32)
//    userKey (64 B)   = decrypt(protectedUserKey EncString type2, stretched)
//

import CommonCrypto
import CryptoKit
import Foundation

enum BitwardenAuthError: Error {
    case network(String)
    case server(Int, String)
    case badResponse
    case unsupportedKdf(Int)
    case keyDecryptFailed
}

struct BitwardenEnrolledKey {
    let userId: String   // Bitwarden account GUID (JWT sub); Keychain account
    let userKey: Data     // 64 bytes
}

struct BitwardenAuthClient {
    let baseURL: URL          // e.g. https://warden.redval.ovh
    var session: URLSession = .shared

    // MARK: - Crypto primitives (pure, unit-tested)

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int = 32) -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                        saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        precondition(status == kCCSuccess)
        return out
    }

    static func masterKey(password: String, email: String, iterations: Int) -> Data {
        pbkdf2SHA256(password: Data(password.utf8),
                     salt: Data(email.lowercased().utf8), iterations: iterations)
    }

    static func masterPasswordHash(masterKey: Data, password: String) -> String {
        pbkdf2SHA256(password: masterKey, salt: Data(password.utf8), iterations: 1).base64EncodedString()
    }

    /// HKDF-SHA256 expand-only (masterKey is already a 32-byte PRK), BW stretch.
    /// 32-byte outputs = a single HMAC block (T(1)), so no counter loop is needed.
    static func stretch(masterKey: Data) -> BitwardenSymmetricKey {
        func expand(_ info: String) -> Data {
            hmacSHA256(key: masterKey, data: Data(info.utf8) + Data([0x01]))
        }
        return BitwardenSymmetricKey(expand("enc") + expand("mac"))!
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        var mac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        mac.withUnsafeMutableBytes { macPtr in
            key.withUnsafeBytes { keyPtr in
                data.withUnsafeBytes { dataPtr in
                    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                           keyPtr.baseAddress, key.count,
                           dataPtr.baseAddress, data.count,
                           macPtr.baseAddress)
                }
            }
        }
        return mac
    }

    /// Decrypt the protected user key EncString using the stretched master key.
    /// Type 2 = stretched (enc+mac). Type 0 = masterKey as enc only (legacy, no MAC).
    static func unwrapUserKey(protectedKey: String, masterKey: Data) -> Data? {
        if protectedKey.hasPrefix("2.") {
            guard let enc = BitwardenEncString(parsing: protectedKey) else { return nil }
            return enc.decrypt(key: stretch(masterKey: masterKey))
        }
        if protectedKey.hasPrefix("0.") {
            let parts = protectedKey.dropFirst(2).split(separator: "|")
            guard parts.count == 2,
                  let iv = Data(base64Encoded: String(parts[0])),
                  let ct = Data(base64Encoded: String(parts[1])) else { return nil }
            return BitwardenEncString.aesCBC(ct, key: masterKey, iv: iv, encrypt: false)
        }
        return nil
    }

    // MARK: - Network enrollment

    func enroll(email: String, password: String, deviceId: String) async throws -> BitwardenEnrolledKey {
        let pre = try await prelogin(email: email)
        guard pre.kdf == 0 else { throw BitwardenAuthError.unsupportedKdf(pre.kdf) }
        let mk = Self.masterKey(password: password, email: email, iterations: pre.iterations)
        let hash = Self.masterPasswordHash(masterKey: mk, password: password)
        let token = try await token(email: email, passwordHash: hash, deviceId: deviceId)
        guard let userKey = Self.unwrapUserKey(protectedKey: token.key, masterKey: mk) else {
            throw BitwardenAuthError.keyDecryptFailed
        }
        return BitwardenEnrolledKey(userId: try Self.jwtSub(token.accessToken), userKey: userKey)
    }

    private struct Prelogin { let kdf: Int; let iterations: Int }

    private func prelogin(email: String) async throws -> Prelogin {
        var req = URLRequest(url: baseURL.appendingPathComponent("identity/accounts/prelogin"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
        let obj = try await json(req)
        // Vaultwarden returns Kdf/KdfIterations (capitalized) or kdf/kdfIterations.
        let kdf = (obj["Kdf"] ?? obj["kdf"]) as? Int ?? 0
        let iters = (obj["KdfIterations"] ?? obj["kdfIterations"]) as? Int ?? 600000
        return Prelogin(kdf: kdf, iterations: iters)
    }

    private struct Token { let accessToken: String; let key: String }

    private func token(email: String, passwordHash: String, deviceId: String) async throws -> Token {
        var req = URLRequest(url: baseURL.appendingPathComponent("identity/connect/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Bitwarden_iOS/1.0 (Reynard)", forHTTPHeaderField: "Device-Type")
        let form: [String: String] = [
            "grant_type": "password",
            "username": email,
            "password": passwordHash,
            "scope": "api offline_access",
            "client_id": "browser",
            "deviceType": "41",            // iOS
            "deviceIdentifier": deviceId,
            "deviceName": "Reynard",
        ]
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let obj = try await json(req)
        guard let access = obj["access_token"] as? String, let key = obj["Key"] as? String ?? obj["key"] as? String else {
            throw BitwardenAuthError.badResponse
        }
        return Token(accessToken: access, key: key)
    }

    // MARK: - Helpers

    private func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw BitwardenAuthError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw BitwardenAuthError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw BitwardenAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BitwardenAuthError.badResponse
        }
        return obj
    }

    static func jwtSub(_ jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { throw BitwardenAuthError.badResponse }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = obj["sub"] as? String else { throw BitwardenAuthError.badResponse }
        return sub
    }

    static func formEncode(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }
}
