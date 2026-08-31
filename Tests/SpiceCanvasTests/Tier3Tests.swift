import Testing
import SpiceWire
@testable import SpiceCanvas

@Test func horizontalStrokePaintsTheLine() {
    let seg = SpicePathSegment(flags: PathFlags.begin | PathFlags.end,
                               points: [FixedPoint(x: 2 * 16, y: 3 * 16), FixedPoint(x: 8 * 16, y: 3 * 16)])
    let mask = Tier3.strokeMask(SpicePath(segments: [seg]),
                                in: SpiceRect(top: 0, left: 0, bottom: 10, right: 10))
    #expect(mask.covers(x: 5, y: 3))       // on the line
    #expect(!mask.covers(x: 5, y: 7))      // off the line
    #expect(!mask.covers(x: 0, y: 3))      // before the start
}

@Test func bezierSegmentRasterizes() {
    let seg = SpicePathSegment(flags: PathFlags.begin | PathFlags.end | PathFlags.bezier,
                               points: [FixedPoint(x: 0, y: 0),
                                        FixedPoint(x: 5 * 16, y: 0), FixedPoint(x: 5 * 16, y: 5 * 16),
                                        FixedPoint(x: 10 * 16, y: 5 * 16)])
    let mask = Tier3.strokeMask(SpicePath(segments: [seg]),
                                in: SpiceRect(top: 0, left: 0, bottom: 10, right: 12))
    #expect(mask.coverage.contains { $0 != 0 })
}

/// A CG stroke path running exactly along an integer coordinate straddles the two pixel rows (or
/// columns) either side of it at ~50% coverage each, because CG treats integer coordinates as grid
/// lines between pixels rather than pixel centers. `fix_to_int` (spice-common canvas_base.c:53-62)
/// rounds a FIXED28_4 to the nearest *pixel address*, and the resulting integer feeds directly into
/// a Bresenham "zero-width line" rasterizer (spice-common lines.c, `spice_canvas_zero_line`) that
/// lights exactly that pixel row/column, not a boundary between two. `Tier3.strokeMask` must offset
/// path coordinates by +0.5 so an integer guest coordinate lands on a pixel center, matching that
/// convention — this test fails (rows 2 and 4 come back non-zero too) without the offset.
@Test func horizontalStrokeDoesNotBleedIntoNeighboringRows() {
    let seg = SpicePathSegment(flags: PathFlags.begin | PathFlags.end,
                               points: [FixedPoint(x: 2 * 16, y: 3 * 16), FixedPoint(x: 8 * 16, y: 3 * 16)])
    let mask = Tier3.strokeMask(SpicePath(segments: [seg]),
                                in: SpiceRect(top: 0, left: 0, bottom: 10, right: 10))
    for x in 3 ..< 8 {
        #expect(!mask.covers(x: x, y: 2), "row above the line must be untouched at x=\(x)")
        #expect(!mask.covers(x: x, y: 4), "row below the line must be untouched at x=\(x)")
        #expect(mask.covers(x: x, y: 3), "the line's own row must be fully covered at x=\(x)")
    }
}

/// Same straddle risk, vertical axis: a stroke along an integer x must not bleed into the columns
/// either side of it.
@Test func verticalStrokeDoesNotBleedIntoNeighboringColumns() {
    let seg = SpicePathSegment(flags: PathFlags.begin | PathFlags.end,
                               points: [FixedPoint(x: 4 * 16, y: 2 * 16), FixedPoint(x: 4 * 16, y: 8 * 16)])
    let mask = Tier3.strokeMask(SpicePath(segments: [seg]),
                                in: SpiceRect(top: 0, left: 0, bottom: 10, right: 10))
    for y in 3 ..< 8 {
        #expect(!mask.covers(x: 3, y: y), "column left of the line must be untouched at y=\(y)")
        #expect(!mask.covers(x: 5, y: y), "column right of the line must be untouched at y=\(y)")
        #expect(mask.covers(x: 4, y: y), "the line's own column must be fully covered at y=\(y)")
    }
}

// MARK: - TEXT (task 7)

private func create(_ w: UInt32, _ h: UInt32) -> DisplayMessage {
    var b = SpiceWriter(); b.u32(0); b.u32(w); b.u32(h); b.u32(32); b.u32(1)
    return try! DisplayMessage(type: DisplayServerMsg.surfaceCreate.rawValue, payload: b.bytes)
}
private func drawBase(_ w: inout SpiceWriter, _ box: SpiceRect) {
    w.u32(0); w.i32(box.top); w.i32(box.left); w.i32(box.bottom); w.i32(box.right); w.u8(0)
}
private func writeBrush(_ w: inout SpiceWriter, _ color: UInt32?) {
    if let color { w.u8(1); w.u32(color) } else { w.u8(0) }
}
/// Follows Task 2's `drawTextParsesGlyphs` wire layout (Tests/SpiceWireTests/DisplayMessageTests.swift):
/// DrawBase, str ptr, back_area, fore brush, back brush, fore_mode, back_mode, then (at the str
/// pointer) length/flags/glyphs. `box` defaults to a non-zero, non-surface-clamped origin distinct
/// from every `renderPos` used below, so a mask-origin bug that leaked the bbox-relative convention
/// (`dst - box.topLeft + pos`, used by every *other* mask on this milestone) would either place the
/// glyph off-surface or at the wrong pixel — see `textDrawsGlyphWithForeBrush`.
private func textDraw(glyphData: [UInt8], w gw: UInt16, h gh: UInt16, at renderPos: SpicePoint,
                      origin: SpicePoint = SpicePoint(x: 0, y: 0),
                      box: SpiceRect = SpiceRect(top: 1, left: 1, bottom: 8, right: 16),
                      backArea: SpiceRect = SpiceRect(top: 0, left: 0, bottom: 0, right: 0),
                      backColor: UInt32? = nil,
                      color: UInt32) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box)
    let strPtr = w.bytes.count; w.u32(0)
    w.i32(backArea.top); w.i32(backArea.left); w.i32(backArea.bottom); w.i32(backArea.right)
    writeBrush(&w, color); writeBrush(&w, backColor)
    w.u16(ROPD.opPut); w.u16(ROPD.opPut)
    w.patchU32(at: strPtr, UInt32(w.bytes.count))
    w.u16(1); w.u8(UInt8(StringFlags.rasterA1 | StringFlags.topDown))
    w.i32(renderPos.x); w.i32(renderPos.y); w.i32(origin.x); w.i32(origin.y)
    w.u16(gw); w.u16(gh)
    w.bytes(glyphData)
    return try! DisplayMessage(type: DisplayServerMsg.drawText.rawValue, payload: w.bytes)
}

@Test func a1GlyphMaskIsMSBFirst() {
    // 0b1100_0000 is deliberately asymmetric under bit-reversal: MSB-first lights the two
    // LEFTMOST pixels, LSB-first would light the two rightmost. The obvious choice here,
    // 0b1000_0001, is a bit-palindrome and passes whichever order the decoder uses.
    let g = RasterGlyph(renderPos: SpicePoint(x: 4, y: 2), origin: SpicePoint(x: 0, y: 0),
                        width: 8, height: 1, data: [0b1100_0000])
    let m = Tier3.glyphMask(g, bpp: 1, topDown: true)
    #expect(m.covers(x: 4, y: 2))           // bit 7 → leftmost pixel
    #expect(m.covers(x: 5, y: 2))           // bit 6
    #expect(!m.covers(x: 10, y: 2))         // set only if the decoder were LSB-first
    #expect(!m.covers(x: 11, y: 2))
}

@Test func a4GlyphHighNibbleFirst() {
    let g = RasterGlyph(renderPos: SpicePoint(x: 0, y: 0), origin: SpicePoint(x: 0, y: 0),
                        width: 2, height: 1, data: [0xF0])
    let m = Tier3.glyphMask(g, bpp: 4, topDown: true)
    #expect(m.covers(x: 0, y: 0) && !m.covers(x: 1, y: 0))
}

@Test func bottomUpGlyphFlips() {
    let g = RasterGlyph(renderPos: SpicePoint(x: 0, y: 0), origin: SpicePoint(x: 0, y: 0),
                        width: 8, height: 2, data: [0xFF, 0x00])    // first row in data = bottom row
    let m = Tier3.glyphMask(g, bpp: 1, topDown: false)
    #expect(!m.covers(x: 0, y: 0) && m.covers(x: 0, y: 1))
}

/// Pins that `glyph_origin` (the second `SpicePoint` in `RasterGlyph`) participates in placement —
/// spice-common `canvas_raster_glyph_box` (canvas_base.c:1566-1573) adds it to `render_pos` for both
/// axes. A glyph whose mask origin were just `renderPos` (per the milestone's original assumption)
/// would place this glyph at (4, 2), not (14, 22).
@Test func glyphOriginShiftsPlacement() {
    let g = RasterGlyph(renderPos: SpicePoint(x: 4, y: 2), origin: SpicePoint(x: 10, y: 20),
                        width: 8, height: 1, data: [0b1000_0001])
    let m = Tier3.glyphMask(g, bpp: 1, topDown: true)
    #expect(m.covers(x: 14, y: 22))
    #expect(!m.covers(x: 4, y: 2))
}

@Test func textDrawsGlyphWithForeBrush() async throws {
    let c = Canvas(); await c.apply(create(16, 8))
    await c.apply(textDraw(glyphData: [0xFF], w: 8, h: 1, at: SpicePoint(x: 3, y: 4), color: 0x00FF00))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 3, y: 4) & 0xFFFFFF == 0x00FF00)
    #expect(s.pixel(x: 3, y: 5) & 0xFFFFFF == 0)
}

/// Back-area fill lands first, then the glyph paints over it — spice-common `canvas_draw_text`
/// (sw_canvas.c:1073-1093) fills `back_area ∩ bbox ∩ clip` before compositing the glyph mask.
@Test func textPaintsBackAreaThenGlyph() async throws {
    let c = Canvas(); await c.apply(create(16, 8))
    await c.apply(textDraw(glyphData: [0xFF], w: 8, h: 1, at: SpicePoint(x: 3, y: 4),
                          backArea: SpiceRect(top: 1, left: 1, bottom: 8, right: 16), backColor: 0x0000FF,
                          color: 0x00FF00))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 3, y: 4) & 0xFFFFFF == 0x00FF00)   // glyph pixel: fore wins over back
    #expect(s.pixel(x: 1, y: 1) & 0xFFFFFF == 0x0000FF)   // back area, no glyph there
    #expect(s.pixel(x: 0, y: 0) & 0xFFFFFF == 0)          // outside the box entirely: untouched
}
