import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
