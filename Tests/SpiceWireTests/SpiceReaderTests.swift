import Testing
@testable import SpiceWire

@Test func readsLittleEndianScalars() throws {
    var r = SpiceReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
    #expect(try r.u8() == 0x01)
    #expect(try r.u16() == 0x0302)
    #expect(try r.u32() == 0x07060504)
    #expect(try r.u64() == 0x0F0E0D0C0B0A0908)
    #expect(r.remaining == 0)
}

@Test func truncatedReadThrowsNotTraps() {
    var r = SpiceReader([0x01, 0x02])
    #expect(throws: WireError.truncated(needed: 4, available: 2)) { try r.u32() }
    #expect(r.offset == 0)  // failed read does not advance
}

@Test func pointerReaderIsRelativeToBase() throws {
    var r = SpiceReader([0xAA, 0xBB, 0x42, 0x00, 0x00, 0x00])
    _ = try r.u16()
    var sub = try r.reader(at: 2)
    #expect(try sub.u32() == 0x42)
    #expect(throws: WireError.badOffset(7)) { _ = try r.reader(at: 7) }
}

@Test func writerRoundTrips() throws {
    var w = SpiceWriter()
    w.u8(1); w.u16(0x0302); w.u32(0x07060504); w.u64(0x0F0E0D0C0B0A0908); w.i32(-1)
    w.patchU32(at: 3, 0xDEADBEEF)
    var r = SpiceReader(w.bytes)
    #expect(try r.u8() == 1)
    #expect(try r.u16() == 0x0302)
    #expect(try r.u32() == 0xDEADBEEF)
    #expect(try r.u64() == 0x0F0E0D0C0B0A0908)
    #expect(try r.i32() == -1)
}
