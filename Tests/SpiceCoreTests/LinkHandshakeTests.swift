import Testing
import Foundation
import Security
import SpiceWire
@testable import SpiceCore

/// Server-side bytes: header + reply (with given common caps) + link result 0.
private func serverBytes(commonCaps: [UInt32], pubkey: [UInt8]) -> [UInt8] {
    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(0)
    let start = w.bytes.count
    w.u32(0); w.bytes(pubkey); w.u32(1); w.u32(0); w.u32(178)
    w.u32(commonCaps.reduce(0) { $0 | (1 << $1) })
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    w.u32(0) // SpiceLinkResult ok
    return w.bytes
}

private func keypair() throws -> (SecKey, [UInt8]) {
    var err: Unmanaged<CFError>?
    let priv = try #require(SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024] as CFDictionary, &err))
    let pub = try #require(SecKeyCopyPublicKey(priv))
    let pkcs1 = try #require(SecKeyCopyExternalRepresentation(pub, &err)) as Data
    return (priv, Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1)))
}

@Test func handshakeWithAuthSelectionSendsMechanismThenTicket() async throws {
    let (priv, spki) = try keypair()
    let t = InMemoryTransport(input: serverBytes(commonCaps: [CommonCap.protocolAuthSelection, CommonCap.authSpice, CommonCap.miniHeader], pubkey: spki))
    let result = try await LinkHandshake.perform(on: t, connectionID: 0, channel: .init(type: .main, id: 0), channelCaps: CapabilitySet(), password: "pw")
    #expect(result.miniHeader)
    let written = await t.written
    var r = SpiceReader(written)
    _ = try r.bytes(16)                       // link header
    let messSize = Int(SpiceReader(Array(written[12 ..< 16])).u32Unchecked())
    _ = try r.bytes(messSize)
    #expect(try r.u32() == CommonCap.authSpice)  // auth mechanism
    let ticket = try r.bytes(128)
    var err: Unmanaged<CFError>?
    let plain = try #require(SecKeyCreateDecryptedData(priv, .rsaEncryptionOAEPSHA1, Data(ticket) as CFData, &err)) as Data
    #expect(plain == Data("pw".utf8) + [0])
    #expect(r.remaining == 0)
}

/// spice-server decides whether a 4-byte auth mechanism precedes the ticket by testing
/// PROTOCOL_AUTH_SELECTION in *the client's* link message. Sending the mechanism without
/// advertising the capability shifts the ticket by four bytes and the server's RSA decrypt fails.
@Test func advertisesAuthSelectionWheneverMechanismIsSent() async throws {
    let (_, spki) = try keypair()
    let t = InMemoryTransport(input: serverBytes(commonCaps: [CommonCap.protocolAuthSelection, CommonCap.authSpice, CommonCap.miniHeader], pubkey: spki))
    _ = try await LinkHandshake.perform(on: t, connectionID: 0, channel: .init(type: .main, id: 0), channelCaps: CapabilitySet(), password: "pw")
    let written = await t.written

    var r = SpiceReader(written)
    _ = try r.bytes(16)                                   // link header
    _ = try r.u32()                                       // connection id
    _ = try r.u8(); _ = try r.u8()                        // channel type, id
    let commonWords = try r.u32()
    _ = try r.u32()                                       // num channel caps
    _ = try r.u32()                                       // caps offset
    #expect(commonWords == 1)
    let caps = try r.u32()
    #expect(caps & (1 << CommonCap.protocolAuthSelection) != 0)
    #expect(caps & (1 << CommonCap.authSpice) != 0)
    #expect(caps & (1 << CommonCap.miniHeader) != 0)
    // and the mechanism itself still follows the link mess
    #expect(try r.u32() == CommonCap.authSpice)
}

@Test func handshakeWithoutAuthSelectionSendsTicketOnly() async throws {
    let (_, spki) = try keypair()
    let t = InMemoryTransport(input: serverBytes(commonCaps: [CommonCap.authSpice], pubkey: spki))
    let result = try await LinkHandshake.perform(on: t, connectionID: 0, channel: .init(type: .main, id: 0), channelCaps: CapabilitySet(), password: "pw")
    #expect(!result.miniHeader)
    let written = await t.written
    let messSize = Int(SpiceReader(Array(written[12 ..< 16])).u32Unchecked())
    #expect(written.count == 16 + messSize + 128)
}

@Test func linkErrorSurfacesAsSpiceError() async throws {
    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(178)
    w.u32(LinkError.needSecured.rawValue); w.bytes([UInt8](repeating: 0, count: 162)); w.u32(0); w.u32(0); w.u32(178)
    let t = InMemoryTransport(input: w.bytes)
    await #expect(throws: SpiceError.self) {
        _ = try await LinkHandshake.perform(on: t, connectionID: 0, channel: .init(type: .main, id: 0), channelCaps: CapabilitySet(), password: nil)
    }
}
