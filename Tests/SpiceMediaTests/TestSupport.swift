import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing

/// Fills the top half of the image with `top` and the bottom half with `bottom`, so decoded output
/// can be checked for both channel order (BGRA vs RGBA) and row order (top-down vs bottom-up) —
/// a solid single-color frame can't distinguish either. Shared by `VideoDecoderTests` and
/// `StreamPlayerTests`.
func jpegFrame(width: Int, height: Int, top: (r: UInt8, g: UInt8, b: UInt8), bottom: (r: UInt8, g: UInt8, b: UInt8)) throws -> [UInt8] {
    var px = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0 ..< height {
        let c = y < height / 2 ? top : bottom
        for x in 0 ..< width {
            let i = (y * width + x) * 4
            px[i] = c.b; px[i + 1] = c.g; px[i + 2] = c.r
        }
    }
    let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return [UInt8](data as Data)
}

/// Solid-color convenience over the two-tone helper above.
func jpegFrame(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> [UInt8] {
    try jpegFrame(width: width, height: height, top: (r, g, b), bottom: (r, g, b))
}

/// The libopus-encoded tone from `Tools/opusref.c`: `[u32 LE length][bytes]` × 100.
func opusFixturePackets() throws -> [[UInt8]] {
    let url = try #require(Bundle.module.url(forResource: "tone-48k-stereo.opus", withExtension: "bin", subdirectory: "Fixtures"))
    let data = [UInt8](try Data(contentsOf: url))
    var packets: [[UInt8]] = []
    var i = 0
    while i + 4 <= data.count {
        let len = Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
        i += 4
        guard i + len <= data.count else { break }
        packets.append(Array(data[i ..< i + len])); i += len
    }
    return packets
}
