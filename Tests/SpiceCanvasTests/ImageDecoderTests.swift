import Testing
import CSpiceCodec
import SpiceWire
@testable import SpiceCanvas

private func img(_ type: ImageType, w: UInt32, h: UInt32, body: (inout SpiceWriter) -> Void) throws -> SpiceImage {
    var wr = SpiceWriter(); wr.u64(1); wr.u8(type.rawValue); wr.u8(0); wr.u32(w); wr.u32(h); body(&wr)
    return try SpiceImage(reader: SpiceReader(wr.bytes), base: SpiceReader(wr.bytes))
}

@Test func decodes24BitBottomUpBitmap() throws {
    let i = try img(.bitmap, w: 1, h: 2) { w in
        w.u8(BitmapFormat.bit24.rawValue); w.u8(0); w.u32(1); w.u32(2); w.u32(4); w.u32(0)   // stride 4 (padded)
        w.bytes([0, 0, 255, 0]); w.bytes([255, 0, 0, 0])      // row0 (bottom) red, row1 (top) blue
    }
    var d = ImageDecoder()
    let out = try d.decode(i, cache: nil)
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
    let out = try d.decode(i, cache: nil)
    #expect(out.pixel(x: 0, y: 0) == 0xFFFF_0000 && out.pixel(x: 1, y: 0) == 0xFF00_FF00)
}

@Test func decodesQuicViaCodec() throws {
    // Encode a 3x2 red image with the vendored encoder, then decode through ImageDecoder.
    let src: [UInt8] = Array(repeating: [0, 0, 255, 255] as [UInt8], count: 6).flatMap { $0 }
    var enc = [UInt8](repeating: 0, count: 4096)
    let n = src.withUnsafeBufferPointer { s in enc.withUnsafeMutableBufferPointer { e in sc_quic_encode_rgb32(s.baseAddress, 3, 2, 12, e.baseAddress, e.count) } }
    let i = try img(.quic, w: 3, h: 2) { w in w.u32(UInt32(n)); w.bytes(Array(enc[0 ..< Int(n)])) }
    var d = ImageDecoder()
    #expect(try d.decode(i, cache: nil).pixel(x: 2, y: 1) == 0xFFFF_0000)
}

@Test func fromCacheMissThrows() throws {
    let i = try img(.fromCache, w: 1, h: 1) { _ in }
    var d = ImageDecoder()
    let cache = ImageCache()
    #expect(throws: CanvasError.self) { _ = try d.decode(i, cache: cache) }
}
