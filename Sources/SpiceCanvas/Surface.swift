import SpiceWire

/// Not Sendable; owned by the `Canvas` actor.
final class Surface {
    let id: UInt32
    let width: Int, height: Int
    let isPrimary: Bool
    let stride: Int
    var pixels: [UInt8]

    init(id: UInt32, width: Int, height: Int, isPrimary: Bool) {
        self.id = id; self.width = width; self.height = height; self.isPrimary = isPrimary
        stride = width * 4
        pixels = [UInt8](repeating: 0, count: stride * height)
        for i in Swift.stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 0xFF }
    }

    var bounds: SpiceRect { SpiceRect(top: 0, left: 0, bottom: Int32(height), right: Int32(width)) }

    func snapshot() -> DecodedImage { DecodedImage(width: width, height: height, pixels: pixels, hasAlpha: false) }

    func extract(_ r: SpiceRect) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(Int(r.width) * Int(r.height) * 4)
        for y in Int(r.top) ..< Int(r.bottom) {
            let s = y * stride + Int(r.left) * 4
            out.append(contentsOf: pixels[s ..< s + Int(r.width) * 4])
        }
        return out
    }
}
