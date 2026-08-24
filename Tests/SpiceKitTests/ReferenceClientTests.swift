import Foundation
import Testing
import SpiceWire

/// Frames the reference client (remote-viewer, driven by xdotool) sent on its inputs channel,
/// in order, skipping ACK_SYNC/ACK/PONG. If our encoders agree with these bytes they agree with
/// spice-server; our own decoder is not a witness.
private func referenceInputFrames() throws -> [(type: UInt16, payload: [UInt8])] {
    let url = try #require(Bundle.module.url(forResource: "win-inputs.c2s", withExtension: "bin", subdirectory: "Fixtures"))
    let b = [UInt8](try Data(contentsOf: url))
    var r = SpiceReader(b)
    try r.skip(12); let linkSize = Int(try r.u32()); try r.skip(linkSize)
    try r.skip(4 + Link.ticketBytes)
    var out: [(UInt16, [UInt8])] = []
    while r.remaining >= DataHeader.miniSize {
        let h = try DataHeader(mini: &r)
        let p = try r.bytes(Int(h.size))
        if h.type > 100 { out.append((h.type, p)) }
    }
    return out
}

/// The dev server advertises SPICE_INPUTS_CAP_KEY_SCANCODE (see `referenceServerAdvertisesKeyScancode`
/// below), so the reference client sends every key through KEY_SCANCODE (104) rather than
/// KEY_DOWN(101)/KEY_UP(102) — combining a quick tap's press and release into a single frame. The
/// dev guest is also in client mouse mode (a USB tablet), so pointer motion arrives as absolute
/// MOUSE_POSITION rather than relative MOUSE_MOTION.
@Test func referenceClientKeyAndMouseEncodings() throws {
    let frames = try referenceInputFrames()
    func payloads(_ type: InputsClientMsg) -> [[UInt8]] { frames.filter { $0.type == type.rawValue }.map(\.payload) }

    let scancodes = payloads(.keyScancode)
    for s in [XTScancode(0x1E), XTScancode(0x53, extended: true), XTScancode(0x4B, extended: true)] {
        let tapped = ClientMessage.keyScancode(s, pressed: true) + ClientMessage.keyScancode(s, pressed: false)
        #expect(scancodes.contains(tapped))
    }
    #expect(payloads(.keyDown).isEmpty)
    #expect(payloads(.keyUp).isEmpty)

    #expect(payloads(.mousePress).contains(ClientMessage.mousePress(.left, buttons: [.left])))
    #expect(payloads(.mouseRelease).contains(ClientMessage.mouseRelease(.left, buttons: [])))
    #expect(payloads(.mousePress).contains(ClientMessage.mousePress(.right, buttons: [.right])))
    #expect(payloads(.mousePress).contains(ClientMessage.mousePress(.up, buttons: [])))
    #expect(!payloads(.keyModifiers).isEmpty)

    #expect(payloads(.mouseMotion).isEmpty)
    let positions = payloads(.mousePosition)
    #expect(!positions.isEmpty)
    for p in positions {
        #expect(p.count == 11)
        #expect(p.last == 0)   // display_id
    }
}

/// Checks the *server's* advertised channel caps (from the link reply), not the client's own —
/// the client's outgoing link mess for this recording advertises zero inputs channel caps of its
/// own; it is the server's advertisement that spice-gtk's `spice_channel_test_capability` gates on.
@Test func referenceServerAdvertisesKeyScancode() throws {
    let url = try #require(Bundle.module.url(forResource: "win-inputs.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    var r = SpiceReader([UInt8](try Data(contentsOf: url)))
    let size = try SpiceLinkReply.parseHeader(&r)
    var body = SpiceReader(try r.bytes(size))
    let reply = try SpiceLinkReply(reader: &body)
    #expect(reply.channelCaps.contains(InputsCap.keyScancode))
}
