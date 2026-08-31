import Testing
import SpiceWire
@testable import SpiceCanvas

private func surface(_ w: Int, _ h: Int, fill: UInt8) -> Surface {
    let s = Surface(id: 0, width: w, height: h, isPrimary: true)
    for i in 0 ..< s.pixels.count where i % 4 != 3 { s.pixels[i] = fill }
    return s
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
