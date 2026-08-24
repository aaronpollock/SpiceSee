import Foundation
import Security
import SpiceCore
import SpiceWire

// Copied from `Tests/SpiceCoreTests/TestSupport.swift`: SPM test targets cannot share sources
// without a helper target, which is not worth it for two small helpers.

/// Link header + reply (fresh RSA key, MINI_HEADER + AUTH_SPICE) + link result OK, so a
/// channel's `open` succeeds against an `InMemoryTransport`. `body` follows as mini-header frames.
func fakeLink(channelCaps: UInt32 = 0, body: [UInt8]) throws -> [UInt8] {
    var err: Unmanaged<CFError>?
    guard let priv = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024] as CFDictionary, &err),
          let pub = SecKeyCopyPublicKey(priv),
          let pkcs1 = SecKeyCopyExternalRepresentation(pub, &err) as Data? else { throw SpiceError(.auth, underlying: "keygen") }
    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(0)
    let start = w.bytes.count
    w.u32(0); w.bytes(Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1)))
    w.u32(1); w.u32(1); w.u32(178)
    w.u32(1 << CommonCap.miniHeader | 1 << CommonCap.authSpice); w.u32(channelCaps)
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    w.u32(0)                                   // link result
    w.bytes(body)
    return w.bytes
}

func frame(_ type: UInt16, _ payload: [UInt8]) -> [UInt8] {
    ClientMessage.frame(type: type, payload: payload, mini: true, serial: 0)
}
