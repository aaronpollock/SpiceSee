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
