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
}
