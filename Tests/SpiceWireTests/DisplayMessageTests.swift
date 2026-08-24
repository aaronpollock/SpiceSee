import Testing
@testable import SpiceWire

private func base(surface: UInt32 = 0) -> SpiceWriter {
    var w = SpiceWriter()
    w.u32(surface); w.i32(10); w.i32(20); w.i32(30); w.i32(40)   // box top,left,bottom,right
    w.u8(0)                                                       // clip none
    return w
}

@Test func surfaceCreateParses() throws {
    var w = SpiceWriter(); w.u32(0); w.u32(1024); w.u32(768); w.u32(32); w.u32(1)
    let m = try DisplayMessage(type: DisplayServerMsg.surfaceCreate.rawValue, payload: w.bytes)
    guard case let .surfaceCreate(s) = m else { Issue.record("case"); return }
    #expect(s.width == 1024 && s.height == 768 && s.format == .xrgb32 && s.isPrimary)
}

@Test func drawFillSolidParses() throws {
    var w = base()
    w.u8(1); w.u32(0xFF0000)            // brush solid red
    w.u16(ROPD.opPut)
    w.u8(0); w.i32(0); w.i32(0); w.u32(0)  // qmask: flags, pos, bitmap ptr 0
    let m = try DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes)
    guard case let .fill(f) = m else { Issue.record("case"); return }
    #expect(f.base.box == SpiceRect(top: 10, left: 20, bottom: 30, right: 40))
    #expect(f.brush == .solid(0xFF0000))
    #expect(f.rop == ROPD.opPut)
    #expect(f.mask.bitmap == nil)
}

@Test func drawCopyResolvesImagePointer() throws {
    var w = base()
    let ptrIndex = w.bytes.count
    w.u32(0)                                // src_bitmap ptr, patched
    w.i32(0); w.i32(0); w.i32(20); w.i32(20) // src_area
    w.u16(ROPD.opPut); w.u8(0)
    w.u8(0); w.i32(0); w.i32(0); w.u32(0)   // mask
    w.patchU32(at: ptrIndex, UInt32(w.bytes.count))
    w.u64(77); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(20); w.u32(20)
    let m = try DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes)
    guard case let .copy(c) = m else { Issue.record("case"); return }
    #expect(c.source?.descriptor.id == 77)
    #expect(c.sourceArea.width == 20)
}

@Test func unknownTypeIsUnsupportedNotError() throws {
    let m = try DisplayMessage(type: 999, payload: [1, 2, 3])
    guard case let .unsupported(t, p) = m else { Issue.record("case"); return }
    #expect(t == 999 && p == [1, 2, 3])
}

@Test func displayInitEncodes14Bytes() {
    let b = ClientMessage.displayInit(cacheSize: 1 << 20, glzWindowSize: 1 << 16)
    #expect(b.count == 14)
    #expect(b[0] == 1)
}
