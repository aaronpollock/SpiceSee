public enum ImageType: UInt8, Sendable {
    case bitmap = 0, quic = 1, lzPlt = 100, lzRGB = 101, glzRGB = 102, fromCache = 103, surface = 104
    case jpeg = 105, fromCacheLossless = 106, zlibGlzRGB = 107, jpegAlpha = 108, lz4 = 109
}
public enum ImageFlags { public static let cacheMe: UInt8 = 1, highBitsSet: UInt8 = 2, cacheReplaceMe: UInt8 = 4 }
public enum BitmapFormat: UInt8, Sendable { case bit1LE = 1, bit1BE, bit4LE, bit4BE, bit8, bit16, bit24, bit32, rgba, bit8A }
public enum BitmapFlags { public static let palCacheMe: UInt8 = 1, palFromCache: UInt8 = 2, topDown: UInt8 = 4 }

public struct SpicePalette: Sendable, Equatable {
    public var id: UInt64, entries: [UInt32]
    public init(id: UInt64, entries: [UInt32]) { self.id = id; self.entries = entries }
    public init(reader r: inout SpiceReader) throws {
        id = try r.u64()
        let n = try r.u16()
        guard n <= 256 else { throw WireError.badValue(field: "num_ents", value: UInt64(n)) }
        entries = try (0 ..< n).map { _ in try r.u32() }
    }
}

public struct SpiceImageDescriptor: Sendable, Equatable {
    public var id: UInt64, type: ImageType, flags: UInt8, width: UInt32, height: UInt32
    public init(id: UInt64, type: ImageType, flags: UInt8, width: UInt32, height: UInt32) {
        self.id = id; self.type = type; self.flags = flags; self.width = width; self.height = height
    }
    public init(reader r: inout SpiceReader) throws {
        id = try r.u64()
        let t = try r.u8()
        guard let type = ImageType(rawValue: t) else { throw WireError.badValue(field: "image_type", value: UInt64(t)) }
        self.type = type; flags = try r.u8(); width = try r.u32(); height = try r.u32()
        guard width <= 16384, height <= 16384 else { throw WireError.badValue(field: "image_size", value: UInt64(width) << 32 | UInt64(height)) }
    }
}

public struct SpiceBitmap: Sendable, Equatable {
    public var format: BitmapFormat, flags: UInt8, width: UInt32, height: UInt32, stride: UInt32
    public var palette: SpicePalette?, paletteID: UInt64?, data: [UInt8]
    public init(format: BitmapFormat, flags: UInt8, width: UInt32, height: UInt32, stride: UInt32,
                palette: SpicePalette?, paletteID: UInt64?, data: [UInt8]) {
        self.format = format; self.flags = flags; self.width = width; self.height = height; self.stride = stride
        self.palette = palette; self.paletteID = paletteID; self.data = data
    }
}

public enum ImagePayload: Sendable, Equatable {
    case bitmap(SpiceBitmap)
    case quic([UInt8]), lzRGB([UInt8]), glzRGB([UInt8])
    /// `glzSize` is the wire's `glz_data_size`: how many bytes the zlib payload inflates to.
    case zlibGlzRGB(glzSize: UInt32, data: [UInt8])
    case lzPlt(flags: UInt8, palette: SpicePalette?, paletteID: UInt64?, data: [UInt8])
    case jpeg([UInt8])
    case jpegAlpha(flags: UInt8, jpegSize: UInt32, data: [UInt8])
    case lz4([UInt8])
    case fromCache, fromCacheLossless
    case surface(UInt32)
}

public struct SpiceImage: Sendable, Equatable {
    public var descriptor: SpiceImageDescriptor
    public var payload: ImagePayload

    public init(descriptor: SpiceImageDescriptor, payload: ImagePayload) {
        self.descriptor = descriptor; self.payload = payload
    }

    public static func at(pointer: UInt32, base: SpiceReader) throws -> SpiceImage? {
        if pointer == 0 { return nil }
        return try SpiceImage(reader: try base.reader(at: pointer), base: base)
    }

    private static func sizedData(_ r: inout SpiceReader) throws -> [UInt8] {
        let n = try r.u32()
        guard n <= 1 << 26 else { throw WireError.badValue(field: "data_size", value: UInt64(n)) }
        return try r.bytes(Int(n))
    }

    public init(reader: SpiceReader, base: SpiceReader) throws {
        var r = reader
        descriptor = try SpiceImageDescriptor(reader: &r)
        switch descriptor.type {
        case .bitmap:
            let f = try r.u8()
            guard let format = BitmapFormat(rawValue: f) else { throw WireError.badValue(field: "bitmap_format", value: UInt64(f)) }
            let flags = try r.u8(), w = try r.u32(), h = try r.u32(), stride = try r.u32()
            var palette: SpicePalette? = nil, paletteID: UInt64? = nil
            if flags & BitmapFlags.palFromCache != 0 {
                paletteID = try r.u64()
            } else {
                let p = try r.u32()
                if p != 0 { var pr = try base.reader(at: p); palette = try SpicePalette(reader: &pr) }
            }
            let (size, overflow) = stride.multipliedReportingOverflow(by: h)
            guard !overflow, size <= 1 << 26 else { throw WireError.badValue(field: "bitmap_size", value: UInt64(stride)) }
            payload = .bitmap(SpiceBitmap(format: format, flags: flags, width: w, height: h, stride: stride,
                                          palette: palette, paletteID: paletteID, data: try r.bytes(Int(size))))
        case .quic: payload = .quic(try Self.sizedData(&r))
        case .lzRGB: payload = .lzRGB(try Self.sizedData(&r))
        case .glzRGB: payload = .glzRGB(try Self.sizedData(&r))
        case .zlibGlzRGB:
            let glzSize = try r.u32()
            guard glzSize <= 1 << 26 else { throw WireError.badValue(field: "glz_data_size", value: UInt64(glzSize)) }
            payload = .zlibGlzRGB(glzSize: glzSize, data: try Self.sizedData(&r))
        case .lz4: payload = .lz4(try Self.sizedData(&r))
        case .jpeg: payload = .jpeg(try Self.sizedData(&r))
        case .jpegAlpha:
            let flags = try r.u8(), jpegSize = try r.u32()
            payload = .jpegAlpha(flags: flags, jpegSize: jpegSize, data: try Self.sizedData(&r))
        case .lzPlt:
            let flags = try r.u8()
            let n = try r.u32()
            var palette: SpicePalette? = nil, paletteID: UInt64? = nil
            if flags & BitmapFlags.palFromCache != 0 { paletteID = try r.u64() }
            else { let p = try r.u32(); if p != 0 { var pr = try base.reader(at: p); palette = try SpicePalette(reader: &pr) } }
            guard n <= 1 << 26 else { throw WireError.badValue(field: "data_size", value: UInt64(n)) }
            payload = .lzPlt(flags: flags, palette: palette, paletteID: paletteID, data: try r.bytes(Int(n)))
        case .fromCache: payload = .fromCache
        case .fromCacheLossless: payload = .fromCacheLossless
        case .surface: payload = .surface(try r.u32())
        }
    }
}
