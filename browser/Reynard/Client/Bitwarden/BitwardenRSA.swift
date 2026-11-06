//
//  BitwardenRSA.swift
//  Reynard
//
//  setupEncryption handshake crypto: the extension sends its RSA-2048 public key
//  as base64 DER SPKI (X.509 SubjectPublicKeyInfo); we wrap the 64-byte shared
//  secret with RSA-OAEP-SHA1 (both OAEP hash and MGF1 are SHA-1, empty label),
//  matching Bitwarden's rsaEncrypt(..., "sha1").
//

import Foundation
import Security

enum BitwardenRSA {
    /// Import a base64 SPKI RSA public key and OAEP-SHA1 encrypt `plaintext`.
    static func encryptOAEPSHA1(_ plaintext: Data, spkiPublicKeyB64: String) -> Data? {
        guard let spki = Data(base64Encoded: spkiPublicKeyB64),
              let pkcs1 = pkcs1FromSPKI(spki) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &err) else { return nil }
        guard let ct = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, plaintext as CFData, &err) else { return nil }
        return ct as Data
    }

    /// Strip the SPKI wrapper to the raw PKCS#1 RSAPublicKey that SecKeyCreateWithData wants.
    /// SPKI = SEQ { SEQ { OID, NULL }, BIT STRING { 0x00, <PKCS1> } }.
    static func pkcs1FromSPKI(_ spki: Data) -> Data? {
        var p = 0
        let b = [UInt8](spki)
        func readLen() -> Int? {
            guard p < b.count else { return nil }
            let first = b[p]; p += 1
            if first < 0x80 { return Int(first) }
            let n = Int(first & 0x7f)
            guard n > 0, n <= 4, p + n <= b.count else { return nil }
            var len = 0
            for _ in 0..<n { len = (len << 8) | Int(b[p]); p += 1 }
            return len
        }
        // outer SEQUENCE
        guard p < b.count, b[p] == 0x30 else { return nil }; p += 1
        guard readLen() != nil else { return nil }
        // algorithm SEQUENCE — skip it entirely
        guard p < b.count, b[p] == 0x30 else { return nil }; p += 1
        guard let algLen = readLen() else { return nil }
        p += algLen
        // BIT STRING
        guard p < b.count, b[p] == 0x03 else { return nil }; p += 1
        guard let bitLen = readLen(), bitLen >= 1, p + bitLen <= b.count else { return nil }
        // first content byte is the unused-bits count (0) — drop it; rest is PKCS#1
        guard b[p] == 0x00 else { return nil }
        return Data(b[(p + 1)..<(p + bitLen)])
    }
}
