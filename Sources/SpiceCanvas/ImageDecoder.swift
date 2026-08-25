import Foundation
import Compression
import ImageIO
import CSpiceCodec
import SpiceWire

/// Stateful (owns the GLZ window) — one per display channel, for the life of the session.
public struct ImageDecoder: ~Copyable {
    private let quic = sc_quic_create()!
    private let lz = sc_lz_create()!
    private let glzWindow = sc_glz_window_create()!
    private let glz: OpaquePointer

    public init() { glz = sc_glz_create(glzWindow)! }
    deinit { sc_glz_destroy(glz); sc_glz_window_destroy(glzWindow); sc_lz_destroy(lz); sc_quic_destroy(quic) }

    public mutating func clearGLZWindow() { sc_glz_window_clear(glzWindow) }

    /// `cache` may be nil in unit tests; FROM_CACHE then throws.
    public mutating func decode(_ image: SpiceImage, cache: ImageCache?) throws -> DecodedImage {
        let w = Int(image.descriptor.width), h = Int(image.descriptor.height)
        switch image.payload {
        case .fromCache, .fromCacheLossless:
            guard let c = cache?[image.descriptor.id] else { throw CanvasError.cacheMiss(image.descriptor.id) }
            return c
        case let .bitmap(b): return try Self.decodeBitmap(b)
        case let .quic(data): return try decodeQuic(data, w, h)
        case let .lzRGB(data): return try decodeLZ(data, palette: nil, w, h)
        case let .lzPlt(_, palette, _, data): return try decodeLZ(data, palette: palette, w, h)
        case let .glzRGB(data): return try decodeGLZ(data)
        case let .zlibGlzRGB(data): return try decodeGLZ(try Self.inflate(data))
        case let .jpeg(data): return try Self.decodeJPEG(data, w, h)
        case .jpegAlpha, .lz4: throw CanvasError.unsupported("image type \(image.descriptor.type)")
        case .surface: throw CanvasError.unsupported("surface-as-image is resolved by Canvas")
        }
    }

    private func decodeQuic(_ data: [UInt8], _ w: Int, _ h: Int) throws -> DecodedImage {
        var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID
        guard data.withUnsafeBufferPointer({ sc_quic_begin(quic, $0.baseAddress, data.count, &ow, &oh, &type) }) == 0,
              Int(ow) == w, Int(oh) == h else { throw CanvasError.decode("quic header") }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard out.withUnsafeMutableBufferPointer({ sc_quic_decode(quic, $0.baseAddress, Int32(w * 4)) }) == 0 else { throw CanvasError.decode("quic") }
        let alpha = type == SC_IMAGE_RGBA
        if !alpha { for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF } }
        return DecodedImage(width: w, height: h, pixels: out, hasAlpha: alpha)
    }

    private func decodeLZ(_ data: [UInt8], palette: SpicePalette?, _ w: Int, _ h: Int) throws -> DecodedImage {
        var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID, topDown: Int32 = 1
        let entries = palette?.entries ?? []
        let ok = data.withUnsafeBufferPointer { d in entries.withUnsafeBufferPointer { p in
            sc_lz_begin(lz, d.baseAddress, data.count, p.baseAddress, Int32(entries.count), &ow, &oh, &type, &topDown) } }
        guard ok == 0, Int(ow) == w, Int(oh) == h else { throw CanvasError.decode("lz header") }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard out.withUnsafeMutableBufferPointer({ sc_lz_decode(lz, $0.baseAddress) }) == 0 else { throw CanvasError.decode("lz") }
        if topDown == 0 { out = Self.flipRows(out, width: w, height: h) }
        let alpha = type == SC_IMAGE_RGBA
        if !alpha { for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF } }
        return DecodedImage(width: w, height: h, pixels: out, hasAlpha: alpha)
    }

    private func decodeGLZ(_ data: [UInt8]) throws -> DecodedImage {
        var p: UnsafePointer<UInt8>? = nil; var w: Int32 = 0, h: Int32 = 0, s: Int32 = 0, topDown: Int32 = 1
        guard data.withUnsafeBufferPointer({ sc_glz_decode(glz, $0.baseAddress, data.count, &p, &w, &h, &s, &topDown) }) == 0, let p else { throw CanvasError.decode("glz") }
        var out = [UInt8](repeating: 0, count: Int(w) * Int(h) * 4)
        for y in 0 ..< Int(h) {
            let srcRow = topDown != 0 ? y : Int(h) - 1 - y
            out.replaceSubrange(y * Int(w) * 4 ..< (y + 1) * Int(w) * 4, with: UnsafeBufferPointer(start: p + srcRow * Int(s), count: Int(w) * 4))
        }
        for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF }
        return DecodedImage(width: Int(w), height: Int(h), pixels: out, hasAlpha: false)
    }

    static func inflate(_ zlib: [UInt8]) throws -> [UInt8] {
        guard zlib.count > 6 else { throw CanvasError.decode("zlib too short") }
        let raw = Array(zlib[2 ..< zlib.count - 4])             // strip 2-byte zlib header and adler32 trailer
        var out = [UInt8](repeating: 0, count: max(raw.count * 8, 1 << 16))
        let n = raw.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
            compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB) } }
        guard n > 0 else { throw CanvasError.decode("zlib") }
        return Array(out[0 ..< n])
    }

    static func flipRows(_ px: [UInt8], width: Int, height: Int) -> [UInt8] {
        let s = width * 4
        var out = [UInt8](repeating: 0, count: px.count)
        for y in 0 ..< height { out.replaceSubrange(y * s ..< (y + 1) * s, with: px[(height - 1 - y) * s ..< (height - y) * s]) }
        return out
    }

    static func decodeBitmap(_ b: SpiceBitmap) throws -> DecodedImage {
        let w = Int(b.width), h = Int(b.height), stride = Int(b.stride)
        var out = [UInt8](repeating: 0xFF, count: w * h * 4)
        let topDown = b.flags & BitmapFlags.topDown != 0
        let pal = b.palette?.entries ?? []
        func palette(_ i: Int) throws -> UInt32 { guard i < pal.count else { throw CanvasError.decode("palette index") }; return pal[i] }
        for y in 0 ..< h {
            let srcRow = (topDown ? y : h - 1 - y) * stride
            let dstRow = y * w * 4
            switch b.format {
            case .bit32:
                out.replaceSubrange(dstRow ..< dstRow + w * 4, with: b.data[srcRow ..< srcRow + w * 4])
                for x in 0 ..< w { out[dstRow + x * 4 + 3] = 0xFF }
            case .rgba:
                out.replaceSubrange(dstRow ..< dstRow + w * 4, with: b.data[srcRow ..< srcRow + w * 4])
            case .bit24:
                for x in 0 ..< w { for c in 0 ..< 3 { out[dstRow + x * 4 + c] = b.data[srcRow + x * 3 + c] } }
            case .bit16:
                for x in 0 ..< w {
                    let v = UInt16(b.data[srcRow + x * 2]) | UInt16(b.data[srcRow + x * 2 + 1]) << 8   // RGB555
                    out[dstRow + x * 4] = UInt8((v & 0x1F) << 3); out[dstRow + x * 4 + 1] = UInt8(((v >> 5) & 0x1F) << 3); out[dstRow + x * 4 + 2] = UInt8(((v >> 10) & 0x1F) << 3)
                }
            case .bit8, .bit8A:
                for x in 0 ..< w { Self.put(&out, dstRow + x * 4, try palette(Int(b.data[srcRow + x]))) }
            case .bit4LE, .bit4BE:
                for x in 0 ..< w {
                    let byte = b.data[srcRow + x / 2]
                    let idx = (b.format == .bit4BE) == (x % 2 == 0) ? byte >> 4 : byte & 0x0F
                    Self.put(&out, dstRow + x * 4, try palette(Int(idx)))
                }
            case .bit1LE, .bit1BE:
                for x in 0 ..< w {
                    let byte = b.data[srcRow + x / 8]
                    let bit = b.format == .bit1BE ? (byte >> (7 - x % 8)) & 1 : (byte >> (x % 8)) & 1
                    Self.put(&out, dstRow + x * 4, try palette(Int(bit)))
                }
            }
        }
        return DecodedImage(width: w, height: h, pixels: out, hasAlpha: b.format == .rgba)
    }

    private static func put(_ out: inout [UInt8], _ i: Int, _ argb: UInt32) {
        out[i] = UInt8(argb & 0xFF); out[i + 1] = UInt8((argb >> 8) & 0xFF); out[i + 2] = UInt8((argb >> 16) & 0xFF); out[i + 3] = 0xFF
    }

    static func decodeJPEG(_ data: [UInt8], _ w: Int, _ h: Int) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CanvasError.decode("jpeg") }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { throw CanvasError.decode("jpeg context") }
        for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF }
        return DecodedImage(width: w, height: h, pixels: out, hasAlpha: false)
    }
}
