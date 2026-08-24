import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNG {
    public static func encode(_ img: DecodedImage) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        // Our buffers are B,G,R,A in memory, which is byteOrder32Little with the alpha *first*
        // in word order. `.first` rather than `.premultipliedFirst` because DecodedImage carries
        // straight alpha; CGImage accepts that even though CGContext would not.
        let info = CGBitmapInfo.byteOrder32Little.rawValue | (img.hasAlpha ? CGImageAlphaInfo.first.rawValue : CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData),
              let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                               space: cs, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw CanvasError.decode("png encode") }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw CanvasError.decode("png finalize") }
        return out as Data
    }

    public static func decode(_ data: Data) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CanvasError.decode("png") }
        var out = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        out.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return DecodedImage(width: cg.width, height: cg.height, pixels: out, hasAlpha: true)
    }
}
