import Testing
import SpiceWire
@testable import SpiceCanvas

private func surface(_ w: Int, _ h: Int, fill: UInt8) -> Surface {
    let s = Surface(id: 0, width: w, height: h, isPrimary: true)
    for i in 0 ..< s.pixels.count where i % 4 != 3 { s.pixels[i] = fill }
    return s
}

// Wire-message builders duplicated from CanvasTests.swift (file-private there) so this file can
// drive a Canvas end to end for `transparentSkipsKeyedPixels`.
private func create(_ w: UInt32, _ h: UInt32) -> DisplayMessage {
    var b = SpiceWriter(); b.u32(0); b.u32(w); b.u32(h); b.u32(32); b.u32(1)
    return try! DisplayMessage(type: DisplayServerMsg.surfaceCreate.rawValue, payload: b.bytes)
}
private func drawBase(_ w: inout SpiceWriter, _ box: SpiceRect) {
    w.u32(0); w.i32(box.top); w.i32(box.left); w.i32(box.bottom); w.i32(box.right); w.u8(0)
}
private func noMask(_ w: inout SpiceWriter) { w.u8(0); w.i32(0); w.i32(0); w.u32(0) }
private func fill(_ box: SpiceRect, color: UInt32) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box); w.u8(1); w.u32(color); w.u16(ROPD.opPut); noMask(&w)
    return try! DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes)
}
/// Follows `copyBitmap`'s pattern (drawBase, ptr to a `.bitmap` image, src_area, src_color,
/// true_color). `src_color` is deliberately a value distinct from `trueColor` — canvas_base.c
/// (canvas_draw_transparent, canvas_base.c:2233) keys off `true_color` only, never `src_color`,
/// so a test where the two match couldn't tell a correct implementation from one keying on the
/// wrong field.
private func transparentDraw(_ box: SpiceRect, pixels: [UInt8], w pw: UInt32, h ph: UInt32, trueColor: UInt32) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box)
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(Int32(ph)); w.i32(Int32(pw))   // source_area
    w.u32(0x00AA_5511)                                       // src_color: distinct from trueColor
    w.u32(trueColor)
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(1); w.u8(ImageType.bitmap.rawValue); w.u8(0); w.u32(pw); w.u32(ph)
    w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(pw); w.u32(ph); w.u32(pw * 4); w.u32(0)
    w.bytes(pixels)
    return try! DisplayMessage(type: DisplayServerMsg.drawTransparent.rawValue, payload: w.bytes)
}

@Test func ropCombineTruthTable() {
    // dst 0b1100, src 0b1010 — every op, from the semantics in canvas_base.c.
    let d: UInt8 = 0b1100, s: UInt8 = 0b1010
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opPut) == s)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opOr) == 0b1110)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opAnd) == 0b1000)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opXor) == 0b0110)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opBlackness) == 0)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opWhiteness) == 0xFF)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opInvers) == ~d)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opPut | ROPD.inversSrc) == ~s)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opAnd | ROPD.inversDest) == (~d & s))
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opOr | ROPD.inversRes) == ~(d | s))
    // BLACKNESS/WHITENESS/INVERS are unconditional (canvas_base.c:307-312): INVERS_RES and
    // INVERS_DEST must not perturb them.
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opBlackness | ROPD.inversRes) == 0)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opWhiteness | ROPD.inversDest) == 0xFF)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opInvers | ROPD.inversDest) == ~d)
}

@Test func solidFillWithXor() {
    let s = surface(2, 1, fill: 0b1100)
    Tier2.draw(s, rect: SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
               source: .solid(0x0A0A0A), rop: ROPD.opXor, mask: nil)
    #expect(s.pixels[0] == 0b1100 ^ 0x0A)
    #expect(s.pixels[3] == 0xFF)                       // alpha forced opaque
}

@Test func patternTilesFromSeed() {
    // 2×1 pattern [red, blue] seeded at x=1: surface x=0 samples pattern x=(0-1) mod 2 = 1 → blue.
    let pat = DecodedImage(width: 2, height: 1,
                           pixels: [0,0,255,255, 255,0,0,255], hasAlpha: false)   // BGRA: red, blue
    let s = surface(4, 1, fill: 0)
    Tier2.draw(s, rect: SpiceRect(top: 0, left: 0, bottom: 1, right: 4),
               source: .pattern(pat, seed: SpicePoint(x: 1, y: 0)), rop: ROPD.opPut, mask: nil)
    #expect(s.pixels[0] == 255 && s.pixels[2] == 0)    // x=0 blue
    #expect(s.pixels[4] == 0 && s.pixels[6] == 255)    // x=1 red
}

@Test func maskGatesTheWrite() {
    let s = surface(2, 1, fill: 0x11)
    let mask = ResolvedMask(width: 2, height: 1, origin: SpicePoint(x: 0, y: 0), coverage: [255, 0])
    Tier2.draw(s, rect: SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
               source: .solid(0xFFFFFF), rop: ROPD.opPut, mask: mask)
    #expect(s.pixels[0] == 0xFF)                       // covered pixel written
    #expect(s.pixels[4] == 0x11)                       // uncovered pixel untouched
}

@Test func scaledNearestDoublesPixels() {
    let src = DecodedImage(width: 2, height: 1, pixels: [1,1,1,255, 9,9,9,255], hasAlpha: false)
    let out = Tier2.scaled(src, from: SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
                           toWidth: 4, toHeight: 1, nearest: true)
    #expect(out.pixels[0] == 1 && out.pixels[4] == 1 && out.pixels[8] == 9 && out.pixels[12] == 9)
}

@Test func scaledInterpolatedProducesPlausibleOutput() {
    // scaleMode 0 (INTERPOLATE) is the wire default, so this is the more likely path in real
    // traffic — a smoke test on dimensions and endpoint colour is enough; ropCombineTruthTable-style
    // exactness isn't the point here.
    let src = DecodedImage(width: 2, height: 1, pixels: [0,0,0,255, 255,255,255,255], hasAlpha: false)
    let out = Tier2.scaled(src, from: SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
                           toWidth: 4, toHeight: 2, nearest: false)
    #expect(out.width == 4 && out.height == 2)
    #expect(out.pixels[0] < 50)                        // left edge stays near black
    #expect(out.pixels[(4 * 2 - 1) * 4] > 200)         // right edge stays near white
}

@Test func rop3KnownCodes() {
    let p: UInt8 = 0xF0, s: UInt8 = 0xCC, d: UInt8 = 0xAA
    #expect(Tier2.rop3(0xCC, p: p, s: s, d: d) == s)          // SRCCOPY
    #expect(Tier2.rop3(0xF0, p: p, s: s, d: d) == p)          // PATCOPY
    #expect(Tier2.rop3(0x55, p: p, s: s, d: d) == ~d)         // DSTINVERT
    #expect(Tier2.rop3(0x5A, p: p, s: s, d: d) == (p ^ d))    // PATINVERT
    #expect(Tier2.rop3(0x66, p: p, s: s, d: d) == (s ^ d))    // SRCINVERT
    #expect(Tier2.rop3(0x00, p: p, s: s, d: d) == 0)          // BLACKNESS
    #expect(Tier2.rop3(0xFF, p: p, s: s, d: d) == 0xFF)       // WHITENESS
}

@Test func transparentSkipsKeyedPixels() async throws {
    let c = Canvas(); await c.apply(create(2, 1))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 1, right: 2), color: 0x112233))
    // 2×1 source: green (the key) and red — only red lands.
    let src: [UInt8] = [0,255,0,255, 0,0,255,255]
    await c.apply(transparentDraw(SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
                                  pixels: src, w: 2, h: 1, trueColor: 0x00FF00))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 0, y: 0) & 0xFFFFFF == 0x112233)       // keyed pixel untouched
    #expect(s.pixel(x: 1, y: 0) & 0xFFFFFF == 0xFF0000)       // red copied
}

private func rop3Draw(_ box: SpiceRect, pixels: [UInt8], w pw: UInt32, h ph: UInt32,
                      brush: UInt32, code: UInt8) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box)
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(Int32(ph)); w.i32(Int32(pw))   // src_area
    w.u8(1); w.u32(brush)                                    // brush: solid
    w.u8(code); w.u8(0)                                      // rop3, scale_mode
    noMask(&w)
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(7); w.u8(ImageType.bitmap.rawValue); w.u8(0); w.u32(pw); w.u32(ph)
    w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(pw); w.u32(ph); w.u32(pw * 4); w.u32(0)
    w.bytes(pixels)
    return try! DisplayMessage(type: DisplayServerMsg.drawRop3.rawValue, payload: w.bytes)
}

/// End-to-end ROP3 through the wire: `rop3KnownCodes` only covers the bit kernel, so nothing pinned
/// which operand the *draw* passes as p, s and d. Each code below isolates one input, and all three
/// values are distinct, so swapping any two roles fails at least one expectation.
@Test func rop3CombinesBrushSourceAndDestByRole() async throws {
    let src: [UInt8] = [0x44, 0x55, 0x66, 0xFF]              // BGRA -> 0x665544
    func run(_ code: UInt8) async throws -> UInt32 {
        let c = Canvas()
        await c.apply(create(1, 1))
        await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 1, right: 1), color: 0x112233))
        await c.apply(rop3Draw(SpiceRect(top: 0, left: 0, bottom: 1, right: 1),
                               pixels: src, w: 1, h: 1, brush: 0x998877, code: code))
        let s = try #require(await c.snapshot(surfaceID: 0))
        return s.pixel(x: 0, y: 0) & 0xFFFFFF
    }
    let patcopy = try await run(0xF0);   #expect(patcopy == 0x998877)   // brush only
    let srccopy = try await run(0xCC);   #expect(srccopy == 0x665544)   // source only
    let dstinv  = try await run(0x55);   #expect(dstinv  == 0xEEDDCC)   // ~dest
    let srcinv  = try await run(0x66);   #expect(srcinv  == 0x777777)   // source ^ dest
}
