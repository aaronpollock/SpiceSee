import Foundation
import Security
import SpiceWire

public enum Ticket {
    /// rsaEncryption OID + NULL, followed by BIT STRING wrapping the PKCS#1 key.
    private static let rsaAlgID: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]

    public static func wrapSPKI(pkcs1: [UInt8]) -> [UInt8] {
        let bitString: [UInt8] = [0x03, 0x81, UInt8(pkcs1.count + 1), 0x00] + pkcs1
        let inner = rsaAlgID + bitString
        return [0x30, 0x81, UInt8(inner.count)] + inner
    }

    /// Strips SubjectPublicKeyInfo and returns the PKCS#1 RSAPublicKey bytes SecKey wants.
    static func unwrapSPKI(_ der: [UInt8]) throws -> [UInt8] {
        // Expected layout: 30 81 LL | 30 0D <algid> | 03 81 LL 00 <pkcs1>
        let prefix = 3 + rsaAlgID.count
        guard der.count > prefix + 4, der[0] == 0x30, Array(der[3 ..< prefix]) == rsaAlgID,
              der[prefix] == 0x03, der[prefix + 1] == 0x81, der[prefix + 3] == 0x00 else {
            throw SpiceError(.auth, underlying: "unexpected public key encoding")
        }
        return Array(der[(prefix + 4)...])
    }

    public static func encrypt(password: String, publicKey der: [UInt8]) throws -> [UInt8] {
        let pw = Array(password.utf8)
        guard pw.count <= Link.maxPasswordLength else { throw SpiceError(.auth, underlying: "password longer than 60 bytes") }
        let pkcs1 = try unwrapSPKI(der)
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attrs as CFDictionary, &err) else {
            throw SpiceError(.auth, underlying: "SecKeyCreateWithData: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(pw + [0]) as CFData, &err) else {
            throw SpiceError(.auth, underlying: "SecKeyCreateEncryptedData: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return [UInt8](cipher as Data)
    }
}
