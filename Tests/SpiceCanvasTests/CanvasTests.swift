import Testing
import SpiceWire
@testable import SpiceCanvas

private func create(_ w: UInt32, _ h: UInt32) -> DisplayMessage {
    var b = SpiceWriter(); b.u32(0); b.u32(w); b.u32(h); b.u32(32); b.u32(1)
    return try! DisplayMessage(type: DisplayServerMsg.surfaceCreate.rawValue, payload: b.bytes)
}
private func drawBase(_ w: inout SpiceWriter, _ box: SpiceRect, clip: [SpiceRect]? = nil) {
    w.u32(0); w.i32(box.top); w.i32(box.left); w.i32(box.bottom); w.i32(box.right)
    if let clip { w.u8(1); w.u32(UInt32(clip.count)); clip.forEach { w.i32($0.top); w.i32($0.left); w.i32($0.bottom); w.i32($0.right) } } else { w.u8(0) }
}
private func noMask(_ w: inout SpiceWriter) { w.u8(0); w.i32(0); w.i32(0); w.u32(0) }
private func fill(_ box: SpiceRect, color: UInt32, clip: [SpiceRect]? = nil) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box, clip: clip); w.u8(1); w.u32(color); w.u16(ROPD.opPut); noMask(&w)
    return try! DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes)
}
private func copyBitmap(_ box: SpiceRect, id: UInt64, flags: UInt8, pixels: [UInt8], w pw: UInt32, h ph: UInt32) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box)
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(Int32(ph)); w.i32(Int32(pw)); w.u16(ROPD.opPut); w.u8(0); noMask(&w)
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(id); w.u8(ImageType.bitmap.rawValue); w.u8(flags); w.u32(pw); w.u32(ph)
    w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(pw); w.u32(ph); w.u32(pw * 4); w.u32(0); w.bytes(pixels)
    return try! DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes)
}
private func copyFromCache(_ box: SpiceRect, id: UInt64, w pw: UInt32, h ph: UInt32) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box)
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(Int32(ph)); w.i32(Int32(pw)); w.u16(ROPD.opPut); w.u8(0); noMask(&w)
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(id); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(pw); w.u32(ph)
    return try! DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes)
}

@Test func surfaceCreateStartsBlack() async throws {
    let c = Canvas(); await c.apply(create(4, 4))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.width == 4 && s.pixel(x: 3, y: 3) == 0xFF00_0000)
}

@Test func fillClipsToBoxAndClipRects() async throws {
    let c = Canvas(); await c.apply(create(8, 8))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 8, right: 8), color: 0x00FF00, clip: [SpiceRect(top: 2, left: 2, bottom: 4, right: 4)]))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 2, y: 2) == 0xFF00_FF00)
    #expect(s.pixel(x: 3, y: 3) == 0xFF00_FF00)
    #expect(s.pixel(x: 4, y: 4) == 0xFF00_0000)
    #expect(s.pixel(x: 1, y: 2) == 0xFF00_0000)
}

@Test func copyBitmapThenFromCache() async throws {
    let c = Canvas(); await c.apply(create(8, 8))
    let px: [UInt8] = [0, 0, 255, 255,  0, 255, 0, 255,  255, 0, 0, 255,  255, 255, 255, 255]   // BGRA: red, green, blue, white
    await c.apply(copyBitmap(SpiceRect(top: 0, left: 0, bottom: 2, right: 2), id: 9, flags: ImageFlags.cacheMe, pixels: px, w: 2, h: 2))
    await c.apply(copyFromCache(SpiceRect(top: 4, left: 4, bottom: 6, right: 6), id: 9, w: 2, h: 2))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 0, y: 0) == 0xFFFF_0000)
    #expect(s.pixel(x: 1, y: 0) == 0xFF00_FF00)
    #expect(s.pixel(x: 4, y: 4) == 0xFFFF_0000)
    #expect(s.pixel(x: 5, y: 5) == 0xFFFF_FFFF)
}

@Test func copyBitsMovesWithinSurface() async throws {
    let c = Canvas(); await c.apply(create(8, 8))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 2, right: 2), color: 0xFF00FF))
    var w = SpiceWriter(); drawBase(&w, SpiceRect(top: 6, left: 6, bottom: 8, right: 8)); w.i32(0); w.i32(0)
    await c.apply(try DisplayMessage(type: DisplayServerMsg.copyBits.rawValue, payload: w.bytes))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 7, y: 7) == 0xFFFF_00FF)
}

@Test func updatesAreEmittedPerDraw() async throws {
    let c = Canvas()
    await c.apply(create(8, 8))
    await c.apply(fill(SpiceRect(top: 1, left: 1, bottom: 3, right: 5), color: 0xFFFFFF))
    var it = c.events.makeAsyncIterator()
    guard case .surfaceCreated(let d)? = await it.next() else { Issue.record("expected created"); return }
    #expect(d.width == 8 && d.isPrimary)
    guard case .updated(let u)? = await it.next() else { Issue.record("expected update"); return }
    #expect(u.surfaceID == 0)
}

@Test func unsupportedMessageEmitsEventAndKeepsGoing() async throws {
    let c = Canvas(); await c.apply(create(2, 2))
    await c.apply(.unsupported(type: 310, payload: []))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 2, right: 2), color: 0x0000FF))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 1, y: 1) == 0xFF00_00FF)
}

@Test func fillWithXorRopInverts() async throws {
    let c = Canvas(); await c.apply(create(2, 2))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 2, right: 2), color: 0xFFFFFF))
    var w = SpiceWriter(); drawBase(&w, SpiceRect(top: 0, left: 0, bottom: 2, right: 2))
    w.u8(1); w.u32(0xFFFFFF); w.u16(ROPD.opXor); noMask(&w)
    await c.apply(try DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 0, y: 0) & 0xFFFFFF == 0)       // white XOR white = black
}

@Test func maskOriginAccountsForNonZeroBoxOrigin() async throws {
    // box.left == 2, mask.pos == (0,0): the mask's own origin sits at the box's origin, not the
    // surface's, so a correct reader must offset the mask index by the box's left/top, not by
    // mask.pos alone.
    let c = Canvas(); await c.apply(create(4, 1))
    var w = SpiceWriter()
    drawBase(&w, SpiceRect(top: 0, left: 2, bottom: 1, right: 4))
    w.u8(1); w.u32(0xFFFFFF); w.u16(ROPD.opPut)
    w.u8(0); w.i32(0); w.i32(0)                              // mask flags=0, pos=(0,0)
    let ptr = w.bytes.count; w.u32(0)
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(0); w.u8(ImageType.bitmap.rawValue); w.u8(0); w.u32(2); w.u32(1)
    w.u8(BitmapFormat.bit1LE.rawValue); w.u8(BitmapFlags.topDown); w.u32(2); w.u32(1); w.u32(1); w.u32(0)
    w.bytes([0x01])                                          // mask-local x=0 covered, x=1 not
    await c.apply(try DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 2, y: 0) == 0xFFFF_FFFF)              // surface x=2 (mask-local x=0): covered
    #expect(s.pixel(x: 3, y: 0) == 0xFF00_0000)              // surface x=3 (mask-local x=1): untouched
}

@Test func hostileCopyBoxIsRejectedNotAllocated() async throws {
    let c = Canvas(); await c.apply(create(4, 4))
    let px: [UInt8] = [0, 0, 255, 255,  0, 255, 0, 255,  255, 0, 0, 255,  255, 255, 255, 255]   // 2×2 BGRA
    var w = SpiceWriter()
    // A box this large would drive Tier2.scaled's allocation into hundreds of exabytes (and
    // overflow Int outright) if `validateBox` didn't refuse it before anything gets sized.
    drawBase(&w, SpiceRect(top: 0, left: 0, bottom: 2_000_000_000, right: 2_000_000_000))
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(2); w.i32(2); w.u16(ROPD.opPut); w.u8(1); noMask(&w)   // scaleMode 1 = nearest
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(1); w.u8(ImageType.bitmap.rawValue); w.u8(0); w.u32(2); w.u32(2)
    w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(2); w.u32(2); w.u32(8); w.u32(0); w.bytes(px)
    await c.apply(try DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes))   // must not crash or hang
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.width == 4 && s.height == 4)
    #expect(s.pixel(x: 0, y: 0) == 0xFF00_0000)              // refused outright, nothing drawn
    // the canvas keeps working after the refusal
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 1, right: 1), color: 0x00FF00))
    #expect(try #require(await c.snapshot(surfaceID: 0)).pixel(x: 0, y: 0) == 0xFF00_FF00)
}

@Test func overhangingBoxScalesAgainstRawBoxNotClampedBox() async throws {
    // An 8-wide surface so the (legitimate, non-hostile) 8-wide box stays within validateBox's
    // area budget despite overhanging. box spans x ∈ [-4, 4) — half of it overhangs the surface's
    // left edge. A correct implementation scales the 2-wide source onto the raw 8-wide box
    // (4× nearest-neighbor) and then clips to the visible x ∈ [0, 4), which is entirely the
    // source's right half (white). Scaling onto the *clamped* (visible-only, 4-wide) box instead
    // — the bug — halves the scale factor, so x=0,1 would wrongly come out black.
    let c = Canvas(); await c.apply(create(8, 1))
    let px: [UInt8] = [0, 0, 0, 255,  255, 255, 255, 255]   // 2×1 BGRA: black, white
    var w = SpiceWriter()
    drawBase(&w, SpiceRect(top: 0, left: -4, bottom: 1, right: 4))
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(1); w.i32(2); w.u16(ROPD.opPut); w.u8(1); noMask(&w)   // scaleMode 1 = nearest
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(1); w.u8(ImageType.bitmap.rawValue); w.u8(0); w.u32(2); w.u32(1)
    w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(2); w.u32(1); w.u32(8); w.u32(0); w.bytes(px)
    await c.apply(try DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes))
    let s = try #require(await c.snapshot(surfaceID: 0))
    for x in 0 ..< 4 { #expect(s.pixel(x: x, y: 0) == 0xFFFF_FFFF, "x=\(x)") }
}

@Test func overhangingMaskedCopyMatchesEquivalentNonOverhangingDraw() async throws {
    // A: box spans x ∈ [-2, 2) (overhangs the left edge by 2), mask.pos=(0,0), a 4-wide mask
    // aligned with the box, coverage [not,not,covered,covered]. The visible surface x ∈ [0, 2)
    // corresponds to box-local x ∈ [2, 4) — covered — sampling source x ∈ [2, 4) (red, white).
    // B is the same outcome expressed with no overhang at all: box x ∈ [0, 2), sourceArea shifted
    // to pick up source x ∈ [2, 4) directly, and mask.pos shifted so the same coverage bits line up.
    // A correct implementation must render A and B identically; keying the mask origin off a
    // *clamped* box shifts A's sample point and breaks that equivalence.
    func maskedOverhangCopy(box: SpiceRect, sourceLeft: Int32, maskPos: SpicePoint) -> DisplayMessage {
        let px: [UInt8] = [255, 0, 0, 255,  0, 255, 0, 255,  0, 0, 255, 255,  255, 255, 255, 255]  // BGRA: blue,green,red,white (4×1)
        var w = SpiceWriter()
        drawBase(&w, box)
        let ptr = w.bytes.count; w.u32(0)
        w.i32(0); w.i32(sourceLeft); w.i32(1); w.i32(sourceLeft + box.width); w.u16(ROPD.opPut); w.u8(0)
        w.u8(0); w.i32(maskPos.x); w.i32(maskPos.y)                      // mask flags=0
        let maskPtr = w.bytes.count; w.u32(0)
        w.patchU32(at: ptr, UInt32(w.bytes.count))
        w.u64(1); w.u8(ImageType.bitmap.rawValue); w.u8(0); w.u32(4); w.u32(1)
        w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(4); w.u32(1); w.u32(16); w.u32(0); w.bytes(px)
        w.patchU32(at: maskPtr, UInt32(w.bytes.count))
        w.u64(2); w.u8(ImageType.bitmap.rawValue); w.u8(0); w.u32(4); w.u32(1)
        w.u8(BitmapFormat.bit1LE.rawValue); w.u8(BitmapFlags.topDown); w.u32(4); w.u32(1); w.u32(1); w.u32(0)
        w.bytes([0b1100])                                                 // index0,1 unset; index2,3 set
        return try! DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes)
    }

    let a = Canvas(); await a.apply(create(4, 1))
    await a.apply(maskedOverhangCopy(box: SpiceRect(top: 0, left: -2, bottom: 1, right: 2), sourceLeft: 0, maskPos: SpicePoint(x: 0, y: 0)))
    let b = Canvas(); await b.apply(create(4, 1))
    await b.apply(maskedOverhangCopy(box: SpiceRect(top: 0, left: 0, bottom: 1, right: 2), sourceLeft: 2, maskPos: SpicePoint(x: 2, y: 0)))

    let sa = try #require(await a.snapshot(surfaceID: 0)), sb = try #require(await b.snapshot(surfaceID: 0))
    for x in 0 ..< 2 { #expect(sa.pixel(x: x, y: 0) == sb.pixel(x: x, y: 0), "x=\(x)") }
    #expect(sa.pixel(x: 0, y: 0) == 0xFFFF_0000)   // red: covered, sampling source x=2
    #expect(sa.pixel(x: 1, y: 0) == 0xFFFF_FFFF)   // white: covered, sampling source x=3
}

@Test func opaqueInversRolesMatchCanvasBaseC() async throws {
    // 1×1 source pixel 0xAA, solid brush 0xCC, combined with AND. canvas_base.c:2423 combines with
    // (ROP_INPUT_BRUSH, ROP_INPUT_SRC): INVERS_SRC inverts the *copied source* (temp), not the
    // brush, and INVERS_DEST does not apply to this combine at all.
    func opaqueDraw(rop: UInt16) -> DisplayMessage {
        var w = SpiceWriter()
        drawBase(&w, SpiceRect(top: 0, left: 0, bottom: 1, right: 1))
        let ptr = w.bytes.count; w.u32(0)
        w.i32(0); w.i32(0); w.i32(1); w.i32(1)              // sourceArea = (0,0,1,1)
        w.u8(1); w.u32(0x00CC_CCCC)                          // brush: solid 0xCCCCCC
        w.u16(rop); w.u8(0)                                  // rop, scaleMode
        noMask(&w)
        w.patchU32(at: ptr, UInt32(w.bytes.count))
        w.u64(1); w.u8(ImageType.bitmap.rawValue); w.u8(0); w.u32(1); w.u32(1)
        w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(1); w.u32(1); w.u32(4); w.u32(0)
        w.bytes([0xAA, 0xAA, 0xAA, 0xFF])
        return try! DisplayMessage(type: DisplayServerMsg.drawOpaque.rawValue, payload: w.bytes)
    }

    let base = Canvas(); await base.apply(create(1, 1))
    await base.apply(opaqueDraw(rop: ROPD.opAnd))
    let baseline = try #require(await base.snapshot(surfaceID: 0)).pixel(x: 0, y: 0)
    #expect(baseline == 0xFF88_8888)                         // 0xAA & 0xCC == 0x88 in every channel

    let inversSrc = Canvas(); await inversSrc.apply(create(1, 1))
    await inversSrc.apply(opaqueDraw(rop: ROPD.opAnd | ROPD.inversSrc))
    #expect(try #require(await inversSrc.snapshot(surfaceID: 0)).pixel(x: 0, y: 0) == 0xFF44_4444)   // (~0xAA) & 0xCC == 0x44

    let inversDest = Canvas(); await inversDest.apply(create(1, 1))
    await inversDest.apply(opaqueDraw(rop: ROPD.opAnd | ROPD.inversDest))
    #expect(try #require(await inversDest.snapshot(surfaceID: 0)).pixel(x: 0, y: 0) == baseline)     // ignored: same as baseline
}

@Test func pngRoundTrip() throws {
    let img = DecodedImage(width: 2, height: 1, pixels: [0, 0, 255, 255, 0, 255, 0, 255], hasAlpha: false)
    let back = try PNG.decode(try PNG.encode(img))
    #expect(back.pixel(x: 0, y: 0) == 0xFFFF_0000 && back.pixel(x: 1, y: 0) == 0xFF00_FF00)
}
