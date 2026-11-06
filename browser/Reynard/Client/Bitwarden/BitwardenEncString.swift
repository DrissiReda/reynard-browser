//
//  BitwardenEncString.swift
//  Reynard
//
//  Bitwarden EncString type 2 (AesCbc256_HmacSha256_B64): AES-256-CBC + PKCS7,
//  encrypt-then-MAC with HMAC-SHA256 over (iv || ciphertext). Used on the native
//  messaging channel with the Bitwarden extension. The 64-byte shared secret is
//  split 0..<32 = AES key, 32..<64 = MAC key (SymmetricCryptoKey layout).
//

import CommonCrypto
import CryptoKit
import Foundation

struct BitwardenEncString {
    /// Serialized form: "2.<iv b64>|<ct b64>|<mac b64>".
    let string: String
    let iv: Data
    let ct: Data
    let mac: Data

    /// The object form the extension speaks on the wire.
    var wireObject: [String: Any] {
        ["encryptedString": string, "encryptionType": 2,
         "data": ct.base64EncodedString(), "iv": iv.base64EncodedString(), "mac": mac.base64EncodedString()]
    }

    init(iv: Data, ct: Data, mac: Data) {
        self.iv = iv; self.ct = ct; self.mac = mac
        self.string = "2." + iv.base64EncodedString() + "|" + ct.base64EncodedString() + "|" + mac.base64EncodedString()
    }

    /// Parse from either the wire object (`encryptedString`/`iv`/`data`/`mac`) or a bare string.
    init?(wire: Any?) {
        if let s = wire as? String { self.init(parsing: s); return }
        guard let d = wire as? [String: Any] else { return nil }
        if let s = d["encryptedString"] as? String { self.init(parsing: s); return }
        guard let ivB = (d["iv"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let ctB = (d["data"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let macB = (d["mac"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        self.init(iv: ivB, ct: ctB, mac: macB)
    }

    init?(parsing s: String) {
        guard s.hasPrefix("2.") else { return nil }
        let body = s.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false)
        guard body.count == 3,
              let ivB = Data(base64Encoded: String(body[0])),
              let ctB = Data(base64Encoded: String(body[1])),
              let macB = Data(base64Encoded: String(body[2])) else { return nil }
        self.init(iv: ivB, ct: ctB, mac: macB)
    }

    // MARK: - Crypto

    static func encrypt(_ plaintext: Data, key: BitwardenSymmetricKey) -> BitwardenEncString {
        var iv = Data(count: 16)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let ct = aesCBC(plaintext, key: key.encKey, iv: iv, encrypt: true)!
        let mac = Self.hmac(iv + ct, key: key.macKey)
        return BitwardenEncString(iv: iv, ct: ct, mac: mac)
    }

    /// Verifies the MAC (constant time) before decrypting. Returns nil on tamper/bad key.
    func decrypt(key: BitwardenSymmetricKey) -> Data? {
        let expected = Self.hmac(iv + ct, key: key.macKey)
        guard Self.constantTimeEqual(expected, mac) else { return nil }
        return Self.aesCBC(ct, key: key.encKey, iv: iv, encrypt: false)
    }

    // MARK: - Primitives

    private static func hmac(_ data: Data, key: Data) -> Data {
        let k = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: k))
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }

    static func aesCBC(_ input: Data, key: Data, iv: Data, encrypt: Bool) -> Data? {
        guard iv.count == kCCBlockSizeAES128, [16, 24, 32].contains(key.count) else { return nil }
        let op = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let outCap = input.count + kCCBlockSizeAES128
        var out = Data(count: outCap)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, input.count,
                                outPtr.baseAddress, outCap, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }
}

/// Bitwarden SymmetricCryptoKey: 64 bytes = 32 AES + 32 HMAC (legacy type).
/// A 32-byte key (enc only, no MAC) is accepted by the extension too but all
/// biometric-channel keys here are 64-byte.
struct BitwardenSymmetricKey {
    let encKey: Data
    let macKey: Data

    init?(_ bytes: Data) {
        guard bytes.count == 64 else { return nil }
        encKey = bytes.prefix(32)
        macKey = bytes.suffix(32)
    }

    static func random() -> (key: BitwardenSymmetricKey, raw: Data) {
        var raw = Data(count: 64)
        _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 64, $0.baseAddress!) }
        return (BitwardenSymmetricKey(raw)!, raw)
    }
}
