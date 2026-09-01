import Compression
import Foundation
import Testing
import SpiceWire
import SpiceCanvas
@testable import SpiceCore

/// No fixture with ZLIB_GLZ_RGB exists — the dev servers sit on a LAN and never classify the
/// client as low-bandwidth, which is what makes spice-server wrap GLZ in zlib (a real Proxmox
/// over a VPN does; that is how the type-107 parse bug shipped). So this test manufactures the
/// wire shape from ground truth: every GLZ draw in the recorded fixture is rewritten as the
/// zlib-wrapped form spice-server would send, and the replay must land on the very same golden.
@Test func zlibWrappedGLZReplaysToTheSameGolden() async throws {
    let url = try #require(Bundle.module.url(forResource: "win-glz-bottomup.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let original = [UInt8](try Data(contentsOf: url))
    var wrapped = 0
    let transformed = try transform(original, wrapped: &wrapped)
    #expect(wrapped > 0, "fixture contained no GLZ draws to rewrite — the test is vacuous")

    let t = InMemoryTransport(input: transformed)
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    for await m in channel.messages { await canvas.apply(m) }
    let id = try #require(await canvas.primarySurfaceID)
    let frame = try #require(await canvas.snapshot(surfaceID: id))

    let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/win-glz-bottomup.golden.png")
    let golden = try PNG.decode(try Data(contentsOf: goldenURL))
    #expect(golden.width == frame.width && golden.height == frame.height)
    var mismatches = 0
    for y in 0 ..< frame.height { for x in 0 ..< frame.width where frame.pixel(x: x, y: y) & 0xFFFFFF != golden.pixel(x: x, y: y) & 0xFFFFFF { mismatches += 1 } }
    #expect(mismatches == 0, "\(mismatches) pixels differ from the GLZ replay's golden")
}

/// Rewrites each DRAW_COPY whose image is GLZ_RGB (102) into ZLIB_GLZ_RGB (107):
/// `glz_data_size` = the original GLZ byte count, then the zlib data sized and inline.
private func transform(_ stream: [UInt8], wrapped: inout Int) throws -> [UInt8] {
    func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }
    func putU32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

    // Link reply: 16-byte header (magic, versions, size), `size` bytes of body, 4-byte result.
    var offset = 16 + u32(stream, 12) + 4
    var out = Array(stream[0 ..< offset])
    while offset + 6 <= stream.count {
        let type = u16(stream, offset)
        let size = u32(stream, offset + 2)
        guard offset + 6 + size <= stream.count else { break }
        var body = Array(stream[offset + 6 ..< offset + 6 + size])
        offset += 6 + size

        if type == 304, let rebuilt = try rewriteCopy(body) { body = rebuilt; wrapped += 1 }
        out += Array(stream[offset - size - 6 ..< offset - size - 4]) // type verbatim
        out += putU32(body.count)
        out += body
    }
    out += Array(stream[offset...])
    return out
}

private func rewriteCopy(_ body: [UInt8]) throws -> [UInt8]? {
    func u32(_ o: Int) -> Int { Int(body[o]) | Int(body[o + 1]) << 8 | Int(body[o + 2]) << 16 | Int(body[o + 3]) << 24 }
    func putU32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    // surfaceID(4) + box(16), then clip: type u8, RECTS carry u32 count + 16 bytes each.
    var o = 20
    let clipType = body[o]; o += 1
    if clipType == 1 { let n = u32(o); o += 4 + 16 * n }
    let ptr = u32(o)
    guard ptr != 0, ptr + 18 <= body.count, body[ptr + 8] == ImageType.glzRGB.rawValue else { return nil }
    let dataSize = u32(ptr + 18)
    // Only the image-is-last layout is rewritten; anything else stays as recorded.
    guard ptr + 22 + dataSize == body.count else { return nil }
    let glz = Array(body[ptr + 22 ..< ptr + 22 + dataSize])
    let zlib = try zlibWrap(glz)
    var out = Array(body[0 ..< ptr + 8])
    out.append(ImageType.zlibGlzRGB.rawValue)
    out += Array(body[ptr + 9 ..< ptr + 18])
    out += putU32(glz.count) + putU32(zlib.count) + zlib
    return out
}

/// spice-server uses zlib's `compress2`: 2-byte header, deflate stream, adler32 trailer.
private func zlibWrap(_ raw: [UInt8]) throws -> [UInt8] {
    var deflated = [UInt8](repeating: 0, count: raw.count + 1024)
    let n = raw.withUnsafeBufferPointer { src in deflated.withUnsafeMutableBufferPointer { dst in
        compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB) } }
    guard n > 0 else { throw SpiceError(.protocolError(.unsupported("test deflate failed"))) }
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    let adler = b << 16 | a
    return [0x78, 0x9C] + deflated[0 ..< n] + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
}
