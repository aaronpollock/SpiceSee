import Testing
@testable import SpiceWire

@Test func linkMessEncodesHeaderAndCaps() throws {
    var common = CapabilitySet(); common.set(CommonCap.authSpice); common.set(CommonCap.miniHeader)
    let mess = SpiceLinkMess(connectionID: 0, channelType: .main, channelID: 0,
                             commonCaps: common, channelCaps: CapabilitySet())
    let bytes = mess.encode()
    var r = SpiceReader(bytes)
    #expect(try r.u32() == 0x51444552)          // "REDQ"
    #expect(try r.u32() == 2)                   // major
    #expect(try r.u32() == 2)                   // minor
    #expect(try r.u32() == UInt32(bytes.count - 16)) // size of link mess
    #expect(try r.u32() == 0)                   // connection id
    #expect(try r.u8() == 1)                    // main
    #expect(try r.u8() == 0)
    #expect(try r.u32() == 1)                   // num common caps
    #expect(try r.u32() == 0)                   // num channel caps
    #expect(try r.u32() == 18)                  // caps offset
    #expect(try r.u32() == (1 << 1) | (1 << 3))
    #expect(r.remaining == 0)
}

@Test func linkReplyParses() throws {
    var w = SpiceWriter()
    w.u32(0x51444552); w.u32(2); w.u32(2); w.u32(0) // header; size patched below
    let start = w.bytes.count
    w.u32(0)                                   // error ok
    w.bytes([UInt8](repeating: 0xAB, count: 162))
    w.u32(1); w.u32(1); w.u32(178)             // num common, num channel, caps offset
    w.u32(0b1011); w.u32(1 << 9)               // common caps, display caps (MJPEG)
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    var r = SpiceReader(w.bytes)
    let size = try SpiceLinkReply.parseHeader(&r)
    #expect(size == 186)
    let reply = try SpiceLinkReply(reader: &r)
    #expect(reply.error == .ok)
    #expect(reply.publicKey.count == 162)
    #expect(reply.commonCaps.contains(CommonCap.miniHeader))
    #expect(reply.channelCaps.contains(DisplayCap.codecMjpeg))
}

@Test func linkReplyRejectsBadMagic() {
    var r = SpiceReader([0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0])
    #expect(throws: WireError.badValue(field: "magic", value: 0)) { _ = try SpiceLinkReply.parseHeader(&r) }
}
