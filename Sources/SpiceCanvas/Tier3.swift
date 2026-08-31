import CoreGraphics
import SpiceWire

/// Tier 3: STROKE (and, per task 7, TEXT) rasterize server-supplied vector geometry into an 8-bit
/// coverage mask via CoreGraphics, then land through Tier2's existing brush/rop/mask machinery.
/// CoreGraphics is used for rasterization only (design spec §4): no `CGBlendMode`, no colour drawn
/// through CG — the mask is plain white-on-black coverage, thresholded to on/off by `ResolvedMask`.
enum Tier3 {
    /// Rasterizes `path` stroked at 1px into an 8-bit coverage mask sized to `rect`.
    ///
    /// `+0.5` on every coordinate is load-bearing, not cosmetic: `FixedPoint` values arrive as
    /// integer guest pixel *addresses* (upstream rounds FIXED28_4 to the nearest one via
    /// `fix_to_int`, canvas_base.c:53-62, then feeds it straight into `spice_canvas_zero_line`'s
    /// Bresenham rasterizer, lines.c — a pixel address lights exactly that row/column). CG instead
    /// treats an integer coordinate as the grid line *between* pixels, so a 1px stroke centred on
    /// an unshifted integer straddles the two rows/columns either side of it at ~50% coverage each.
    /// Shifting by half a pixel moves the centreline onto CG's pixel-center convention so a stroke
    /// at guest row/column N lights exactly N.
    static func strokeMask(_ path: SpicePath, in rect: SpiceRect) -> ResolvedMask {
        let w = Int(rect.width), h = Int(rect.height)
        var coverage = [UInt8](repeating: 0, count: w * h)
        coverage.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Surface y grows down; CG y grows up. Flip once here so callers stay in guest coords.
            ctx.translateBy(x: -CGFloat(rect.left), y: CGFloat(rect.bottom))
            ctx.scaleBy(x: 1, y: -1)
            let cg = CGMutablePath()
            for seg in path.segments {
                guard let first = seg.points.first else { continue }
                if seg.flags & PathFlags.begin != 0 { cg.move(to: CGPoint(x: first.cgX + 0.5, y: first.cgY + 0.5)) }
                if seg.flags & PathFlags.bezier != 0 {
                    var i = 1
                    while i + 2 < seg.points.count {
                        let c1 = seg.points[i], c2 = seg.points[i + 1], end = seg.points[i + 2]
                        cg.addCurve(to: CGPoint(x: end.cgX + 0.5, y: end.cgY + 0.5),
                                    control1: CGPoint(x: c1.cgX + 0.5, y: c1.cgY + 0.5),
                                    control2: CGPoint(x: c2.cgX + 0.5, y: c2.cgY + 0.5))
                        i += 3
                    }
                } else {
                    for p in seg.points.dropFirst() { cg.addLine(to: CGPoint(x: p.cgX + 0.5, y: p.cgY + 0.5)) }
                }
                if seg.flags & PathFlags.close != 0 { cg.closeSubpath() }
            }
            ctx.setLineWidth(1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.addPath(cg)
            ctx.strokePath()
        }
        return ResolvedMask(width: w, height: h, origin: SpicePoint(x: rect.left, y: rect.top), coverage: coverage)
    }

    /// Decodes a glyph's coverage bitmap into a `ResolvedMask` positioned at `render_pos +
    /// glyph_origin` in *absolute* surface coordinates — independent of the draw's `base.box`,
    /// unlike every other mask on this milestone. `canvas_raster_glyph_box` (spice-common
    /// canvas_base.c:1566-1573) adds `glyph_origin` to `render_pos` for both axes, and
    /// `canvas_draw_text` (spice-common sw_canvas.c:1111-1123) composites the resulting mask at
    /// that absolute position; `bbox`/clip only restrict which of those pixels actually land, the
    /// same bbox-as-clip-rect role `base.box` already plays via `forEachClipRect` elsewhere in
    /// `Canvas`. Callers are expected to have bounded `glyph.width`/`height` against the
    /// destination surface (`Canvas.validateRegion`) before calling this, the same way `.copy`/
    /// `.opaque`/`.rop3` bound their own box-sized allocations — this function does not repeat
    /// that check.
    ///
    /// A1 unpacks MSB-first, A4 high-nibble-first (canvas_base.c:1628-1665 — the bpp==1 case
    /// reverses each source byte before packing it LSB-first into the destination, meaning the
    /// wire byte itself is MSB-first; the bpp==4 case assigns `byte & 0xf0` to the first pixel of
    /// a pair and `byte << 4` to the second). A4/A8 partial coverage collapses to on/off here
    /// since `Tier2.draw`'s mask has no graduated-alpha path yet — anti-aliased subpixel text from
    /// QXL is A1 in practice, so this only affects the untested A4/A8 paths.
    ///
    /// Rows are read bottom-up unless `topDown`, matching the QMask bitmap convention used
    /// elsewhere (`Canvas.resolveMask`'s `topDown ? y : height - 1 - y`). Upstream itself has never
    /// implemented `SPICE_STRING_FLAGS_RASTER_TOP_DOWN` (canvas_base.c:1618, `//todo: support
    /// SPICE_STRING_FLAGS_RASTER_TOP_DOWN` — it always assumes bottom-up), so there is no reference
    /// behaviour to match for the true case; honouring the documented flag is a considered choice,
    /// not a guess.
    static func glyphMask(_ glyph: RasterGlyph, bpp: Int, topDown: Bool) -> ResolvedMask {
        let width = Int(glyph.width), height = Int(glyph.height)
        guard width > 0, height > 0 else {
            return ResolvedMask(width: 0, height: 0, origin: glyph.renderPos, coverage: [])
        }
        let rowBytes = (width * bpp + 7) / 8
        var coverage = [UInt8](repeating: 0, count: width * height)
        for row in 0 ..< height {
            let dataRow = topDown ? row : height - 1 - row
            let rowStart = dataRow * rowBytes
            for x in 0 ..< width {
                let on: Bool
                switch bpp {
                case 1:
                    let byteIndex = rowStart + x / 8
                    guard byteIndex < glyph.data.count else { continue }
                    on = (glyph.data[byteIndex] >> (7 - x % 8)) & 1 != 0
                case 4:
                    let byteIndex = rowStart + x / 2
                    guard byteIndex < glyph.data.count else { continue }
                    let byte = glyph.data[byteIndex]
                    on = (x % 2 == 0 ? byte & 0xF0 : byte << 4) != 0
                default:   // A8
                    let byteIndex = rowStart + x
                    guard byteIndex < glyph.data.count else { continue }
                    on = glyph.data[byteIndex] != 0
                }
                if on { coverage[row * width + x] = 0xFF }
            }
        }
        let origin = SpicePoint(x: glyph.renderPos.x + glyph.origin.x, y: glyph.renderPos.y + glyph.origin.y)
        return ResolvedMask(width: width, height: height, origin: origin, coverage: coverage)
    }
}
