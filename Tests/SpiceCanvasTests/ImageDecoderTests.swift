import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CSpiceCodec
import SpiceWire
@testable import SpiceCanvas

private func img(_ type: ImageType, w: UInt32, h: UInt32, body: (inout SpiceWriter) -> Void) throws -> SpiceImage {
    var wr = SpiceWriter(); wr.u64(1); wr.u8(type.rawValue); wr.u8(0); wr.u32(w); wr.u32(h); body(&wr)
    return try SpiceImage(reader: SpiceReader(wr.bytes), base: SpiceReader(wr.bytes))
}

private enum PNGFixtures {
    static func solidJPEG(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = b; pixels[i + 1] = g; pixels[i + 2] = r; pixels[i + 3] = 0xFF }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let cg = ctx.makeImage() else { throw CanvasError.decode("test jpeg context") }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw CanvasError.decode("test jpeg dest") }
        CGImageDestinationAddImage(dst, cg, nil)
        guard CGImageDestinationFinalize(dst) else { throw CanvasError.decode("test jpeg finalize") }
        return [UInt8](data as Data)
    }
}

@Test func decodes24BitBottomUpBitmap() throws {
    let i = try img(.bitmap, w: 1, h: 2) { w in
        w.u8(BitmapFormat.bit24.rawValue); w.u8(0); w.u32(1); w.u32(2); w.u32(4); w.u32(0)   // stride 4 (padded)
        w.bytes([0, 0, 255, 0]); w.bytes([255, 0, 0, 0])      // row0 (bottom) red, row1 (top) blue
    }
    var d = ImageDecoder()
    var palettes = PaletteCache()
    let out = try d.decode(i, cache: nil, palettes: &palettes)
    #expect(out.pixel(x: 0, y: 0) == 0xFF00_00FF)   // top row = last in bottom-up data = blue
    #expect(out.pixel(x: 0, y: 1) == 0xFFFF_0000)
}

@Test func decodes8BitPalette() throws {
    let i = try img(.bitmap, w: 2, h: 1) { w in
        w.u8(BitmapFormat.bit8.rawValue); w.u8(BitmapFlags.topDown); w.u32(2); w.u32(1); w.u32(2)
        let palPtr = w.bytes.count; w.u32(0)
        w.bytes([0, 1])
        w.patchU32(at: palPtr, UInt32(w.bytes.count))
        w.u64(5); w.u16(2); w.u32(0x00FF0000); w.u32(0x0000FF00)
    }
    var d = ImageDecoder()
    var palettes = PaletteCache()
    let out = try d.decode(i, cache: nil, palettes: &palettes)
    #expect(out.pixel(x: 0, y: 0) == 0xFFFF_0000 && out.pixel(x: 1, y: 0) == 0xFF00_FF00)
}

@Test func decodesQuicViaCodec() throws {
    // Encode a 3x2 red image with the vendored encoder, then decode through ImageDecoder.
    let src: [UInt8] = Array(repeating: [0, 0, 255, 255] as [UInt8], count: 6).flatMap { $0 }
    var enc = [UInt8](repeating: 0, count: 4096)
    let n = src.withUnsafeBufferPointer { s in enc.withUnsafeMutableBufferPointer { e in sc_quic_encode_rgb32(s.baseAddress, 3, 2, 12, e.baseAddress, e.count) } }
    let i = try img(.quic, w: 3, h: 2) { w in w.u32(UInt32(n)); w.bytes(Array(enc[0 ..< Int(n)])) }
    var d = ImageDecoder()
    var palettes = PaletteCache()
    #expect(try d.decode(i, cache: nil, palettes: &palettes).pixel(x: 2, y: 1) == 0xFFFF_0000)
}

@Test func fromCacheMissThrows() throws {
    let i = try img(.fromCache, w: 1, h: 1) { _ in }
    var d = ImageDecoder()
    var palettes = PaletteCache()
    let cache = ImageCache()
    #expect(throws: CanvasError.self) { _ = try d.decode(i, cache: cache, palettes: &palettes) }
}

@Test func bitmapPaletteRoundTripsThroughCache() throws {
    // An 8-bit bitmap with an inline palette flagged PAL_CACHE_ME, then the same image
    // with PAL_FROM_CACHE referencing the id: both must decode to the same pixels.
    var palettes = PaletteCache()
    let pal = SpicePalette(id: 9, entries: [0x0000FF, 0x00FF00] + Array(repeating: 0, count: 254))
    let withPal = SpiceBitmap(format: .bit8, flags: BitmapFlags.palCacheMe | BitmapFlags.topDown,
                              width: 2, height: 1, stride: 2, palette: pal, paletteID: nil, data: [0, 1])
    var d = ImageDecoder()
    let first = try d.decodeBitmap(withPal, palettes: &palettes)
    #expect(first.pixel(x: 0, y: 0) & 0xFFFFFF == 0x0000FF)
    let fromCache = SpiceBitmap(format: .bit8, flags: BitmapFlags.palFromCache | BitmapFlags.topDown,
                                width: 2, height: 1, stride: 2, palette: nil, paletteID: 9, data: [0, 1])
    let second = try d.decodeBitmap(fromCache, palettes: &palettes)
    #expect(second.pixels == first.pixels)
}

@Test func missingCachedPaletteThrows() throws {
    var palettes = PaletteCache()
    let b = SpiceBitmap(format: .bit8, flags: BitmapFlags.palFromCache, width: 1, height: 1,
                        stride: 1, palette: nil, paletteID: 42, data: [0])
    var d = ImageDecoder()
    #expect(throws: CanvasError.self) { _ = try d.decodeBitmap(b, palettes: &palettes) }
}

@Test func jpegAlphaCarriesTheAlphaPlane() throws {
    // RGB from a solid red JPEG, alpha from an LZ XXXA plane encoded by the bridge test helper.
    let w = 8, h = 8
    let red = try PNGFixtures.solidJPEG(width: w, height: h, r: 255, g: 0, b: 0)   // helper below
    var alphaPixels = [UInt8](repeating: 0, count: w * h * 4)
    for i in stride(from: 3, to: alphaPixels.count, by: 4) { alphaPixels[i] = 0x80 }
    var lz = [UInt8](repeating: 0, count: 1 << 16)
    let n = alphaPixels.withUnsafeBufferPointer { src in lz.withUnsafeMutableBufferPointer { dst in
        sc_lz_encode_xxxa(src.baseAddress, Int32(w), Int32(h), Int32(w * 4), dst.baseAddress, dst.count) } }
    #expect(n > 0)
    let payload = ImagePayload.jpegAlpha(flags: 1, jpegSize: UInt32(red.count), data: red + lz[0 ..< Int(n)])
    let desc = SpiceImageDescriptor(id: 0, type: .jpegAlpha, flags: 0, width: UInt32(w), height: UInt32(h))
    var d = ImageDecoder(); var palettes = PaletteCache()
    let img = try d.decode(SpiceImage(descriptor: desc, payload: payload), cache: nil, palettes: &palettes)
    #expect(img.hasAlpha)
    #expect(img.pixels[3] == 0x80)                       // alpha from the LZ plane
    #expect(img.pixels[2] > 200 && img.pixels[0] < 50)   // red from the JPEG (tolerance: lossy)
}
