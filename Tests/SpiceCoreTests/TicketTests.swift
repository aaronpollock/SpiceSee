import Testing
import Foundation
import Security
@testable import SpiceCore

@Test func ticketDecryptsWithMatchingPrivateKey() throws {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024]
    var err: Unmanaged<CFError>?
    let priv = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, &err))
    let pub = try #require(SecKeyCopyPublicKey(priv))
    let pkcs1 = try #require(SecKeyCopyExternalRepresentation(pub, &err)) as Data
    // Wrap PKCS#1 in SubjectPublicKeyInfo, as the server sends it.
    let spki = Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1))
    #expect(spki.count == 162)

    let cipher = try Ticket.encrypt(password: "hunter2", publicKey: spki)
    #expect(cipher.count == 128)

    let plain = try #require(SecKeyCreateDecryptedData(priv, .rsaEncryptionOAEPSHA1, Data(cipher) as CFData, &err)) as Data
    #expect(plain == Data("hunter2".utf8) + [0])
}

@Test func passwordTooLongThrows() {
    #expect(throws: SpiceError.self) { _ = try Ticket.encrypt(password: String(repeating: "x", count: 61), publicKey: [UInt8](repeating: 0, count: 162)) }
}
