public struct DecodedImage: Sendable, Equatable {
    public var width: Int, height: Int
    public var pixels: [UInt8]   // BGRA, tightly packed
    public var hasAlpha: Bool
    public init(width: Int, height: Int, pixels: [UInt8], hasAlpha: Bool) {
        self.width = width; self.height = height; self.pixels = pixels; self.hasAlpha = hasAlpha
    }
    /// 0xAARRGGBB.
    public func pixel(x: Int, y: Int) -> UInt32 {
        let i = (y * width + x) * 4
        return UInt32(pixels[i + 3]) << 24 | UInt32(pixels[i + 2]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i])
    }
}

public enum CanvasError: Error, Sendable {
    case cacheMiss(UInt64), noSurface(UInt32), decode(String), unsupported(String)
}
