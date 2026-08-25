import Testing
import CSpiceCodec

private func gradient(_ w: Int, _ h: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0 ..< h { for x in 0 ..< w {
        let i = (y * w + x) * 4
        p[i] = UInt8(x & 0xFF); p[i + 1] = UInt8(y & 0xFF); p[i + 2] = UInt8((x + y) & 0xFF); p[i + 3] = 0xFF
    } }
    return p
}

@Test func quicRoundTripsRGB32() throws {
    let (w, h) = (37, 23)
    let src = gradient(w, h)
    var enc = [UInt8](repeating: 0, count: 1 << 20)
    let n = src.withUnsafeBufferPointer { s in enc.withUnsafeMutableBufferPointer { e in
        sc_quic_encode_rgb32(s.baseAddress, Int32(w), Int32(h), Int32(w * 4), e.baseAddress, e.count) } }
    #expect(n > 0)
    let ctx = sc_quic_create()!; defer { sc_quic_destroy(ctx) }
    var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID
    #expect(enc.withUnsafeBufferPointer { sc_quic_begin(ctx, $0.baseAddress, Int(n), &ow, &oh, &type) } == 0)
    #expect(ow == Int32(w) && oh == Int32(h) && type == SC_IMAGE_RGB32)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    #expect(out.withUnsafeMutableBufferPointer { sc_quic_decode(ctx, $0.baseAddress, Int32(w * 4)) } == 0)
    for i in stride(from: 0, to: out.count, by: 4) { #expect(out[i ..< i + 3] == src[i ..< i + 3]) }  // alpha byte is undefined for RGB32
}

@Test func quicRejectsGarbage() {
    let ctx = sc_quic_create()!; defer { sc_quic_destroy(ctx) }
    var w: Int32 = 0, h: Int32 = 0, t = SC_IMAGE_INVALID
    let junk = [UInt8](repeating: 0xA5, count: 64)
    #expect(junk.withUnsafeBufferPointer { sc_quic_begin(ctx, $0.baseAddress, 64, &w, &h, &t) } < 0)
}

@Test func lzRoundTripsRGB32() throws {
    let (w, h) = (40, 9)
    let src = gradient(w, h)
    var enc = [UInt8](repeating: 0, count: 1 << 20)
    let n = src.withUnsafeBufferPointer { s in enc.withUnsafeMutableBufferPointer { e in
        sc_lz_encode_rgb32(s.baseAddress, Int32(w), Int32(h), Int32(w * 4), e.baseAddress, e.count) } }
    #expect(n > 0)
    let ctx = sc_lz_create()!; defer { sc_lz_destroy(ctx) }
    var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID, topDown: Int32 = 0
    #expect(enc.withUnsafeBufferPointer { sc_lz_begin(ctx, $0.baseAddress, Int(n), nil, 0, &ow, &oh, &type, &topDown) } == 0)
    #expect(ow == Int32(w) && oh == Int32(h))
    var out = [UInt8](repeating: 0, count: w * h * 4)
    #expect(out.withUnsafeMutableBufferPointer { sc_lz_decode(ctx, $0.baseAddress) } == 0)
    for i in stride(from: 0, to: out.count, by: 4) { #expect(out[i ..< i + 3] == src[i ..< i + 3]) }
}

@Test func glzWindowLifecycle() {
    let win = sc_glz_window_create()!
    let dec = sc_glz_create(win)!
    var out: UnsafePointer<UInt8>? = nil; var w: Int32 = 0, h: Int32 = 0, s: Int32 = 0, topDown: Int32 = 1
    let junk = [UInt8](repeating: 0xFF, count: 32)
    #expect(junk.withUnsafeBufferPointer { sc_glz_decode(dec, $0.baseAddress, 32, &out, &w, &h, &s, &topDown) } < 0)
    sc_glz_destroy(dec); sc_glz_window_destroy(win)
}
