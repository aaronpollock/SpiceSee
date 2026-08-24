import Testing
import Foundation
import Security
import SpiceWire
@testable import SpiceCore

@Test func mainChannelBringUp() async throws {
    var err: Unmanaged<CFError>?
    let priv = try #require(SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024] as CFDictionary, &err))
    let pub = try #require(SecKeyCopyPublicKey(priv))
    let pkcs1 = try #require(SecKeyCopyExternalRepresentation(pub, &err)) as Data
    let spki = Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1))

    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(0)
    let start = w.bytes.count
    w.u32(0); w.bytes(spki); w.u32(1); w.u32(0); w.u32(178); w.u32(1 << CommonCap.miniHeader | 1 << CommonCap.authSpice)
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    w.u32(0)                                                        // link result
    var mi = SpiceWriter(); [42, 1, 3, 2, 0, 10, 0, 0].forEach { mi.u32(UInt32($0)) }
    w.bytes(ClientMessage.frame(type: MainServerMsg.`init`.rawValue, payload: mi.bytes, mini: true, serial: 0))
    var cl = SpiceWriter(); cl.u32(2); cl.u8(2); cl.u8(0); cl.u8(3); cl.u8(0)
    w.bytes(ClientMessage.frame(type: MainServerMsg.channelsList.rawValue, payload: cl.bytes, mini: true, serial: 0))
    var mm = SpiceWriter(); mm.u32(777)
    w.bytes(ClientMessage.frame(type: MainServerMsg.multiMediaTime.rawValue, payload: mm.bytes, mini: true, serial: 0))

    let t = InMemoryTransport(input: w.bytes)
    let main = try await MainChannel.open(transport: t, password: nil)
    let info = await main.info
    #expect(info.connectionID == 42)
    #expect(info.mainInit.agentTokens == 10)
    #expect(info.channels == [.init(type: .display, id: 0), .init(type: .inputs, id: 0)])

    var events: [MainMessage] = []
    for await e in main.events { events.append(e) }
    guard case let .multiMediaTime(m)? = events.first else { Issue.record("expected mm time"); return }
    #expect(m.time == 777)

    // ATTACH_CHANNELS was sent after MAIN_INIT
    let written = await t.written
    let attach = ClientMessage.frame(type: MainClientMsg.attachChannels.rawValue, payload: [], mini: true, serial: 1)
    #expect(written.suffix(attach.count) == ArraySlice(attach))
}
