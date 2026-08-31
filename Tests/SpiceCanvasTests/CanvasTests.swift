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

@Test func pngRoundTrip() throws {
    let img = DecodedImage(width: 2, height: 1, pixels: [0, 0, 255, 255, 0, 255, 0, 255], hasAlpha: false)
    let back = try PNG.decode(try PNG.encode(img))
    #expect(back.pixel(x: 0, y: 0) == 0xFFFF_0000 && back.pixel(x: 1, y: 0) == 0xFF00_FF00)
}
