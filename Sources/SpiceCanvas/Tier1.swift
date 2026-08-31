import SpiceWire

enum Tier1 {
    /// Copies `src` (tight BGRA) at `srcOrigin` into `dst` over `rect`. Alpha ignored.
    static func copy(into dst: Surface, rect: SpiceRect, src: DecodedImage, srcOrigin: SpicePoint) {
        let rowBytes = Int(rect.width) * 4
        for y in 0 ..< Int(rect.height) {
            let sy = Int(srcOrigin.y) + y
            guard sy >= 0, sy < src.height else { continue }
            let sx = Int(srcOrigin.x)
            let visible = max(0, min(rowBytes / 4, src.width - sx)) * 4
            guard visible > 0, sx >= 0 else { continue }
            let s = (sy * src.width + sx) * 4
            let d = (Int(rect.top) + y) * dst.stride + Int(rect.left) * 4
            dst.pixels.replaceSubrange(d ..< d + visible, with: src.pixels[s ..< s + visible])
        }
    }

    static func fill(_ dst: Surface, rect: SpiceRect, color: UInt32) {
        let b = UInt8(color & 0xFF), g = UInt8((color >> 8) & 0xFF), r = UInt8((color >> 16) & 0xFF)
        for y in Int(rect.top) ..< Int(rect.bottom) {
            var i = y * dst.stride + Int(rect.left) * 4
            for _ in 0 ..< Int(rect.width) { dst.pixels[i] = b; dst.pixels[i + 1] = g; dst.pixels[i + 2] = r; dst.pixels[i + 3] = 0xFF; i += 4 }
        }
    }

    /// Straight-alpha "over" with a constant multiplier (0...255).
    static func alphaBlend(into dst: Surface, rect: SpiceRect, src: DecodedImage, srcOrigin: SpicePoint, alpha: UInt8) {
        for y in 0 ..< Int(rect.height) {
            let sy = Int(srcOrigin.y) + y; guard sy >= 0, sy < src.height else { continue }
            for x in 0 ..< Int(rect.width) {
                let sx = Int(srcOrigin.x) + x; guard sx >= 0, sx < src.width else { continue }
                let s = (sy * src.width + sx) * 4, d = (Int(rect.top) + y) * dst.stride + (Int(rect.left) + x) * 4
                let a = Int(src.hasAlpha ? src.pixels[s + 3] : 255) * Int(alpha) / 255
                for c in 0 ..< 3 { dst.pixels[d + c] = UInt8((Int(src.pixels[s + c]) * a + Int(dst.pixels[d + c]) * (255 - a)) / 255) }
            }
        }
    }

    /// In-surface move; handles overlap by extracting first.
    static func copyBits(_ dst: Surface, rect: SpiceRect, from: SpicePoint) {
        let srcRect = SpiceRect(top: from.y, left: from.x, bottom: from.y + rect.height, right: from.x + rect.width)
        guard let clipped = srcRect.intersection(dst.bounds) else { return }
        let img = DecodedImage(width: Int(clipped.width), height: Int(clipped.height), pixels: dst.extract(clipped), hasAlpha: false)
        let target = SpiceRect(top: rect.top + (clipped.top - srcRect.top), left: rect.left + (clipped.left - srcRect.left),
                               bottom: rect.top + (clipped.bottom - srcRect.top), right: rect.left + (clipped.right - srcRect.left))
        copy(into: dst, rect: target, src: img, srcOrigin: SpicePoint(x: 0, y: 0))
    }
}
