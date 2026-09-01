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
    public mutating func decode(_ image: SpiceImage, cache: ImageCache?, palettes: inout PaletteCache) throws -> DecodedImage {
        let w = Int(image.descriptor.width), h = Int(image.descriptor.height)
        switch image.payload {
        case .fromCache, .fromCacheLossless:
            guard let c = cache?[image.descriptor.id] else { throw CanvasError.cacheMiss(image.descriptor.id) }
            return c
        case let .bitmap(b): return try decodeBitmap(b, palettes: &palettes)
        case let .quic(data): return try decodeQuic(data, w, h)
        case let .lzRGB(data): return try decodeLZ(data, palette: nil, w, h)
        case let .lzPlt(flags, palette, paletteID, data):
            let pal = try Self.resolvePalette(flags: flags, palette: palette, paletteID: paletteID, palettes: &palettes)
            return try decodeLZ(data, palette: pal, w, h)
        case let .glzRGB(data): return try decodeGLZ(data)
        case let .zlibGlzRGB(glzSize, data): return try decodeGLZ(try Self.inflate(data, uncompressedSize: Int(glzSize)))
        case let .jpeg(data): return try Self.decodeJPEG(data, w, h)
        case let .jpegAlpha(flags, jpegSize, data): return try decodeJPEGAlpha(flags: flags, jpegSize: jpegSize, data: data, w, h)
        case .lz4: throw CanvasError.unsupported("image type \(image.descriptor.type)")
        case .surface: throw CanvasError.unsupported("surface-as-image is resolved by Canvas")
        }
    }

    /// Resolves a bitmap/lzPlt palette against `palettes`, storing an inline one flagged `PAL_CACHE_ME`.
    private static func resolvePalette(flags: UInt8, palette: SpicePalette?, paletteID: UInt64?, palettes: inout PaletteCache) throws -> SpicePalette? {
        if flags & BitmapFlags.palFromCache != 0 {
            guard let id = paletteID, let cached = palettes[id] else { throw CanvasError.cacheMiss(paletteID ?? 0) }
            return cached
        }
        if flags & BitmapFlags.palCacheMe != 0, let p = palette { palettes.store(p) }
        return palette
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
        // XXXA is alpha-only (jpeg-alpha's plane); an lzRGB/lzPlt payload claiming it is malformed —
        // upstream's canvas_get_lz treats this as unreachable, and decoding it here would silently
        // produce an opaque black image instead of throwing.
        guard ok == 0, type != SC_IMAGE_XXXA, Int(ow) == w, Int(oh) == h else { throw CanvasError.decode("lz header") }
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

    /// `uncompressedSize` comes off the wire (`glz_data_size`, capped at parse), so the buffer is
    /// exact — guessing from the input size under-allocates on well-compressed repaints. Anything
    /// but a full, exact inflation fails closed.
    static func inflate(_ zlib: [UInt8], uncompressedSize: Int) throws -> [UInt8] {
        guard zlib.count > 6 else { throw CanvasError.decode("zlib too short") }
        guard uncompressedSize > 0 else { throw CanvasError.decode("zlib declares empty output") }
        let raw = Array(zlib[2 ..< zlib.count - 4])             // strip 2-byte zlib header and adler32 trailer
        // One spare byte: the decoder truncates silently at the buffer's end, so an exact-size
        // buffer cannot tell "fit exactly" from "there was more" — with the spare, a stream
        // bigger than declared lands on size+1 and the equality below catches both mismatches.
        var out = [UInt8](repeating: 0, count: uncompressedSize + 1)
        let n = raw.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
            compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB) } }
        guard n == uncompressedSize else { throw CanvasError.decode("zlib inflated \(n), declared \(uncompressedSize)") }
        out.removeLast()
        return out
    }

    static func flipRows(_ px: [UInt8], width: Int, height: Int) -> [UInt8] {
        let s = width * 4
        var out = [UInt8](repeating: 0, count: px.count)
        for y in 0 ..< height { out.replaceSubrange(y * s ..< (y + 1) * s, with: px[(height - 1 - y) * s ..< (height - y) * s]) }
        return out
    }

    /// Minimum bytes a row of `format` occupies at `width` pixels. `stride` is server-controlled and
    /// independent of `width`, so it must be checked against this before any row is indexed.
    private static func rowBytes(_ format: BitmapFormat, width w: Int) -> Int {
        switch format {
        case .bit32, .rgba: return w * 4
        case .bit24: return w * 3
        case .bit16: return w * 2
        case .bit8, .bit8A: return w
        case .bit4LE, .bit4BE: return (w + 1) / 2
        case .bit1LE, .bit1BE: return (w + 7) / 8
        }
    }

    mutating func decodeBitmap(_ b: SpiceBitmap, palettes: inout PaletteCache) throws -> DecodedImage {
        let w = Int(b.width), h = Int(b.height), stride = Int(b.stride)
        // Each branch below indexes up to `rowBytes` into every row. The wire only promises
        // `data.count == stride * height`, which a hostile server satisfies by shrinking `stride`
        // below what `width` needs — so the last row's slice would run past `data` and trap.
        guard w >= 0, h >= 0, stride >= Self.rowBytes(b.format, width: w) else {
            throw CanvasError.decode("bitmap stride \(stride) too small for \(w)px \(b.format)")
        }
        guard h == 0 || b.data.count >= (h - 1) * stride + Self.rowBytes(b.format, width: w) else {
            throw CanvasError.decode("bitmap data shorter than stride × height")
        }
        var out = [UInt8](repeating: 0xFF, count: w * h * 4)
        let topDown = b.flags & BitmapFlags.topDown != 0
        let resolved = try Self.resolvePalette(flags: b.flags, palette: b.palette, paletteID: b.paletteID, palettes: &palettes)
        let pal = resolved?.entries ?? []
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

    /// `data` is `jpegSize` bytes of JPEG followed by an LZ XXXA (alpha-only) plane. The alpha plane
    /// is decoded into a scratch buffer and flipped there — flipping after merging into the JPEG
    /// image would corrupt rows, since the merge only touches byte 3 of each pixel.
    private func decodeJPEGAlpha(flags: UInt8, jpegSize: UInt32, data: [UInt8], _ w: Int, _ h: Int) throws -> DecodedImage {
        guard Int(jpegSize) <= data.count else { throw CanvasError.decode("jpeg-alpha size") }
        var img = try Self.decodeJPEG(Array(data[0 ..< Int(jpegSize)]), w, h)
        let alphaData = Array(data[Int(jpegSize)...])
        var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID, lzTopDown: Int32 = 1
        let ok = alphaData.withUnsafeBufferPointer { d in sc_lz_begin(lz, d.baseAddress, alphaData.count, nil, 0, &ow, &oh, &type, &lzTopDown) }
        // Upstream (canvas_base.c) additionally requires the jpeg-alpha flags and the alpha plane's
        // own LZ header agree on orientation; a mismatch is rejected rather than trusted, since
        // trusting the wrong one would merge an upside-down alpha channel silently.
        guard ok == 0, type == SC_IMAGE_XXXA, Int(ow) == w, Int(oh) == h,
              (lzTopDown != 0) == (flags & 1 != 0) else { throw CanvasError.decode("jpeg-alpha plane header") }
        var scratch = [UInt8](repeating: 0, count: w * h * 4)
        guard scratch.withUnsafeMutableBufferPointer({ sc_lz_decode(lz, $0.baseAddress) }) == 0 else { throw CanvasError.decode("jpeg-alpha plane") }
        if flags & 1 == 0 { scratch = Self.flipRows(scratch, width: w, height: h) }
        for i in stride(from: 3, to: scratch.count, by: 4) { img.pixels[i] = scratch[i] }
        img.hasAlpha = true
        return img
    }
}
