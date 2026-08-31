import Accelerate
import SpiceWire

enum PixelSource {
    case image(DecodedImage, origin: SpicePoint)      // src pixel for (x,y) in rect: origin + offset
    case solid(UInt32)                                 // 0x00RRGGBB, SPICE brush color order
    case pattern(DecodedImage, seed: SpicePoint)       // tiled; seed is the pattern origin in surface coords
}

struct ResolvedMask {   // 8-bit coverage, 0 = skip, else apply
    var width: Int, height: Int, origin: SpicePoint
    var coverage: [UInt8]

    func covers(x: Int, y: Int) -> Bool {
        let mx = x - Int(origin.x), my = y - Int(origin.y)
        guard mx >= 0, mx < width, my >= 0, my < height else { return false }
        return coverage[my * width + mx] != 0
    }
}

enum Tier2 {
    static func ropCombine(dst: UInt8, src: UInt8, rop: UInt16) -> UInt8 {
        // INVERS_SRC and INVERS_BRUSH both invert the incoming value; the caller passes whichever
        // pixel stream the command names, so one flag check covers both.
        let s = rop & (ROPD.inversSrc | ROPD.inversBrush) != 0 ? ~src : src
        let d = rop & ROPD.inversDest != 0 ? ~dst : dst
        var r: UInt8
        if rop & ROPD.opPut != 0 { r = s }
        else if rop & ROPD.opOr != 0 { r = d | s }
        else if rop & ROPD.opAnd != 0 { r = d & s }
        else if rop & ROPD.opXor != 0 { r = d ^ s }
        else if rop & ROPD.opBlackness != 0 { r = 0 }
        else if rop & ROPD.opWhiteness != 0 { r = 0xFF }
        else if rop & ROPD.opInvers != 0 { r = ~d }
        else { r = s }
        if rop & ROPD.inversRes != 0 { r = ~r }
        return r
    }

    /// Fast path: PUT with no mask is the 95% case (plain blits/fills) and must not pay for the
    /// general per-pixel loop — it delegates straight to the tier-1 kernels.
    static func draw(_ dst: Surface, rect: SpiceRect, source: PixelSource, rop: UInt16, mask: ResolvedMask?) {
        if mask == nil, rop == ROPD.opPut {
            switch source {
            case let .image(img, origin):
                Tier1.copy(into: dst, rect: rect, src: img, srcOrigin: origin)
                return
            case let .solid(c):
                Tier1.fill(dst, rect: rect, color: c)
                return
            case .pattern:
                break
            }
        }
        let top = max(0, Int(rect.top)), bottom = min(dst.height, Int(rect.bottom))
        let left = max(0, Int(rect.left)), right = min(dst.width, Int(rect.right))
        guard top < bottom, left < right else { return }
        for y in top ..< bottom {
            for x in left ..< right {
                if let mask, !mask.covers(x: x, y: y) { continue }
                let (b, g, r): (UInt8, UInt8, UInt8)
                switch source {
                case let .solid(c):
                    (b, g, r) = (UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF))
                case let .image(img, origin):
                    let sx = Int(origin.x) + x - Int(rect.left), sy = Int(origin.y) + y - Int(rect.top)
                    guard sx >= 0, sx < img.width, sy >= 0, sy < img.height else { continue }
                    let i = (sy * img.width + sx) * 4
                    (b, g, r) = (img.pixels[i], img.pixels[i + 1], img.pixels[i + 2])
                case let .pattern(img, seed):
                    guard img.width > 0, img.height > 0 else { continue }
                    let px = ((x - Int(seed.x)) % img.width + img.width) % img.width
                    let py = ((y - Int(seed.y)) % img.height + img.height) % img.height
                    let i = (py * img.width + px) * 4
                    (b, g, r) = (img.pixels[i], img.pixels[i + 1], img.pixels[i + 2])
                }
                let d = y * dst.stride + x * 4
                dst.pixels[d] = ropCombine(dst: dst.pixels[d], src: b, rop: rop)
                dst.pixels[d + 1] = ropCombine(dst: dst.pixels[d + 1], src: g, rop: rop)
                dst.pixels[d + 2] = ropCombine(dst: dst.pixels[d + 2], src: r, rop: rop)
                dst.pixels[d + 3] = 0xFF
            }
        }
    }

    /// Crops `from` out of `src` (clamped to source bounds — server-controlled geometry) and scales
    /// to `toWidth`×`toHeight`. Interpolated scaling goes through vImage; nearest is a manual loop
    /// (vImage has no nearest mode). vImageScale_ARGB8888 is channel-order-agnostic, so BGRA passes
    /// straight through.
    static func scaled(_ src: DecodedImage, from: SpiceRect, toWidth: Int, toHeight: Int, nearest: Bool) -> DecodedImage {
        let fromWidth = Int(from.width), fromHeight = Int(from.height)
        guard fromWidth > 0, fromHeight > 0, toWidth > 0, toHeight > 0 else {
            return DecodedImage(width: max(toWidth, 0), height: max(toHeight, 0),
                                 pixels: [UInt8](repeating: 0, count: max(toWidth, 0) * max(toHeight, 0) * 4), hasAlpha: src.hasAlpha)
        }

        var cropped = [UInt8](repeating: 0, count: fromWidth * fromHeight * 4)
        for y in 0 ..< fromHeight {
            let sy = Int(from.top) + y
            guard sy >= 0, sy < src.height else { continue }
            let sx0 = Int(from.left)
            let visibleStart = max(0, -sx0), visibleEnd = min(fromWidth, src.width - sx0)
            guard visibleEnd > visibleStart else { continue }
            let s = (sy * src.width + sx0 + visibleStart) * 4
            let d = (y * fromWidth + visibleStart) * 4
            let n = (visibleEnd - visibleStart) * 4
            cropped.replaceSubrange(d ..< d + n, with: src.pixels[s ..< s + n])
        }

        if nearest {
            var out = [UInt8](repeating: 0, count: toWidth * toHeight * 4)
            for y in 0 ..< toHeight {
                let sy = min(fromHeight - 1, y * fromHeight / toHeight)
                for x in 0 ..< toWidth {
                    let sx = min(fromWidth - 1, x * fromWidth / toWidth)
                    let s = (sy * fromWidth + sx) * 4, d = (y * toWidth + x) * 4
                    out[d] = cropped[s]; out[d + 1] = cropped[s + 1]; out[d + 2] = cropped[s + 2]; out[d + 3] = cropped[s + 3]
                }
            }
            return DecodedImage(width: toWidth, height: toHeight, pixels: out, hasAlpha: src.hasAlpha)
        }

        var out = [UInt8](repeating: 0, count: toWidth * toHeight * 4)
        let ok = cropped.withUnsafeMutableBytes { srcBytes in
            out.withUnsafeMutableBytes { dstBytes in
                var srcBuffer = vImage_Buffer(data: srcBytes.baseAddress, height: vImagePixelCount(fromHeight),
                                               width: vImagePixelCount(fromWidth), rowBytes: fromWidth * 4)
                var dstBuffer = vImage_Buffer(data: dstBytes.baseAddress, height: vImagePixelCount(toHeight),
                                               width: vImagePixelCount(toWidth), rowBytes: toWidth * 4)
                return vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
        guard ok else { return scaled(src, from: from, toWidth: toWidth, toHeight: toHeight, nearest: true) }
        return DecodedImage(width: toWidth, height: toHeight, pixels: out, hasAlpha: src.hasAlpha)
    }
}
