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

@Test func drawTransparentParses() throws {
    var w = base()
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(8); w.i32(8)     // src_area
    w.u32(0x00FF00); w.u32(0x00FF00)            // src_color, true_color
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(1); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(8); w.u32(8)
    let m = try DisplayMessage(type: DisplayServerMsg.drawTransparent.rawValue, payload: w.bytes)
    guard case let .transparent(t) = m else { Issue.record("case"); return }
    #expect(t.trueColor == 0x00FF00 && t.sourceArea.width == 8)
}

@Test func drawRop3Parses() throws {
    var w = base()
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(4); w.i32(4)
    w.u8(1); w.u32(0x0000FF)                    // brush solid blue
    w.u8(0xCC); w.u8(0)                          // rop3 SRCCOPY, scale interpolate
    w.u8(0); w.i32(0); w.i32(0); w.u32(0)        // no mask
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(2); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(4); w.u32(4)
    let m = try DisplayMessage(type: DisplayServerMsg.drawRop3.rawValue, payload: w.bytes)
    guard case let .rop3(r) = m else { Issue.record("case"); return }
    #expect(r.rop3 == 0xCC && r.brush == .solid(0x0000FF))
}

@Test func drawStrokeParsesPath() throws {
    var w = base()
    let pathPtr = w.bytes.count; w.u32(0)
    w.u8(0)                                      // line attr: plain
    w.u8(1); w.u32(0xFF0000)                     // brush solid red
    w.u16(ROPD.opPut); w.u16(ROPD.opPut)         // fore_mode, back_mode
    w.patchU32(at: pathPtr, UInt32(w.bytes.count))
    w.u32(1)                                     // one segment
    w.u8(PathFlags.begin | PathFlags.end); w.u32(2)
    w.i32(10 * 16); w.i32(10 * 16)               // FIXED28_4: (10,10)
    w.i32(50 * 16); w.i32(10 * 16)               // (50,10)
    let m = try DisplayMessage(type: DisplayServerMsg.drawStroke.rawValue, payload: w.bytes)
    guard case let .stroke(s) = m else { Issue.record("case"); return }
    #expect(s.path.segments.count == 1)
    #expect(s.path.segments[0].points == [FixedPoint(x: 160, y: 160), FixedPoint(x: 800, y: 160)])
    #expect(s.brush == .solid(0xFF0000))
}

@Test func drawTextParsesGlyphs() throws {
    var w = base()
    let strPtr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(0); w.i32(0)       // back_area empty
    w.u8(1); w.u32(0xFFFFFF)                     // fore solid white
    w.u8(0)                                      // back brush none
    w.u16(ROPD.opPut); w.u16(ROPD.opPut)
    w.patchU32(at: strPtr, UInt32(w.bytes.count))
    w.u16(1); w.u8(UInt8(StringFlags.rasterA1 | StringFlags.topDown))
    w.i32(5); w.i32(7); w.i32(0); w.i32(0)       // render_pos (5,7), origin (0,0)
    w.u16(8); w.u16(2)                            // 8×2 → 1 byte/row A1
    w.bytes([0b1010_1010, 0b0101_0101])
    let m = try DisplayMessage(type: DisplayServerMsg.drawText.rawValue, payload: w.bytes)
    guard case let .text(t) = m else { Issue.record("case"); return }
    #expect(t.str.glyphs.count == 1 && t.str.glyphs[0].data.count == 2)
    #expect(t.str.glyphs[0].renderPos == SpicePoint(x: 5, y: 7))
}

@Test func strokeRejectsOversizedPath() throws {
    var w = base()
    let pathPtr = w.bytes.count; w.u32(0)
    w.u8(0); w.u8(1); w.u32(0xFF0000); w.u16(ROPD.opPut); w.u16(ROPD.opPut)
    w.patchU32(at: pathPtr, UInt32(w.bytes.count))
    w.u32(1)
    w.u8(PathFlags.begin); w.u32(0xFFFF_FFFF)    // hostile point count
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.drawStroke.rawValue, payload: w.bytes)
    }
}

@Test func strokeRejectsOversizedNumSegments() throws {
    var w = base()
    let pathPtr = w.bytes.count; w.u32(0)
    w.u8(0); w.u8(1); w.u32(0xFF0000); w.u16(ROPD.opPut); w.u16(ROPD.opPut)
    w.patchU32(at: pathPtr, UInt32(w.bytes.count))
    w.u32(0xFFFF_FFFF)                           // hostile num_segments
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.drawStroke.rawValue, payload: w.bytes)
    }
}

@Test func strokeRejectsZeroPathPointer() throws {
    var w = base()
    w.u32(0)                                     // path ptr: null
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.drawStroke.rawValue, payload: w.bytes)
    }
}

@Test func textRejectsZeroStrPointer() throws {
    var w = base()
    w.u32(0)                                     // str ptr: null
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.drawText.rawValue, payload: w.bytes)
    }
}

@Test func textRejectsOversizedGlyphDimensions() throws {
    var w = base()
    let strPtr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(0); w.i32(0)       // back_area empty
    w.u8(1); w.u32(0xFFFFFF)                     // fore solid white
    w.u8(0)                                      // back brush none
    w.u16(ROPD.opPut); w.u16(ROPD.opPut)
    w.patchU32(at: strPtr, UInt32(w.bytes.count))
    w.u16(1); w.u8(UInt8(StringFlags.rasterA1))
    w.i32(0); w.i32(0); w.i32(0); w.i32(0)       // render_pos, origin
    w.u16(0xFFFF); w.u16(0xFFFF)                  // hostile width × height
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.drawText.rawValue, payload: w.bytes)
    }
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
