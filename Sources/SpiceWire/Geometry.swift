public struct SpicePoint: Sendable, Equatable {
    public var x: Int32, y: Int32
    public init(x: Int32, y: Int32) { self.x = x; self.y = y }
    public init(reader r: inout SpiceReader) throws { x = try r.i32(); y = try r.i32() }
}

public struct SpiceRect: Sendable, Equatable {
    public var top, left, bottom, right: Int32
    public init(top: Int32, left: Int32, bottom: Int32, right: Int32) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public init(reader r: inout SpiceReader) throws {
        top = try r.i32(); left = try r.i32(); bottom = try r.i32(); right = try r.i32()
        let (_, widthOverflow) = right.subtractingReportingOverflow(left)
        guard !widthOverflow else { throw WireError.badValue(field: "width", value: UInt64(bitPattern: Int64(right))) }
        let (_, heightOverflow) = bottom.subtractingReportingOverflow(top)
        guard !heightOverflow else { throw WireError.badValue(field: "height", value: UInt64(bitPattern: Int64(bottom))) }
    }
    public var width: Int32 { right - left }
    public var height: Int32 { bottom - top }
    public var isEmpty: Bool { right <= left || bottom <= top }
    public func intersection(_ o: SpiceRect) -> SpiceRect? {
        let r = SpiceRect(top: max(top, o.top), left: max(left, o.left), bottom: min(bottom, o.bottom), right: min(right, o.right))
        return r.isEmpty ? nil : r
    }
}

public enum SpiceClip: Sendable, Equatable {
    case none
    case rects([SpiceRect])
    public init(reader r: inout SpiceReader) throws {
        switch try r.u8() {
        case 0: self = .none
        case 1:
            let n = try r.u32()
            guard n <= 1 << 16 else { throw WireError.badValue(field: "num_rects", value: UInt64(n)) }
            self = .rects(try (0 ..< n).map { _ in try SpiceRect(reader: &r) })
        case let t: throw WireError.badValue(field: "clip_type", value: UInt64(t))
        }
    }
}

public enum ROPD {
    public static let inversSrc: UInt16 = 1 << 0, inversBrush: UInt16 = 1 << 1, inversDest: UInt16 = 1 << 2
    public static let opPut: UInt16 = 1 << 3, opOr: UInt16 = 1 << 4, opAnd: UInt16 = 1 << 5, opXor: UInt16 = 1 << 6
    public static let opBlackness: UInt16 = 1 << 7, opWhiteness: UInt16 = 1 << 8, opInvers: UInt16 = 1 << 9
    public static let inversRes: UInt16 = 1 << 10
}

public struct SpiceQMask: Sendable, Equatable {
    public var flags: UInt8
    public var pos: SpicePoint
    public var bitmap: SpiceImage?
    public init(reader r: inout SpiceReader, base: SpiceReader) throws {
        flags = try r.u8(); pos = try SpicePoint(reader: &r)
        bitmap = try SpiceImage.at(pointer: try r.u32(), base: base)
    }
}

public enum MaskFlags { public static let invers: UInt8 = 1 }
public enum PathFlags { public static let begin: UInt8 = 1, end: UInt8 = 2, close: UInt8 = 8, bezier: UInt8 = 16 }
public enum StringFlags { public static let rasterA1: UInt16 = 1, rasterA4: UInt16 = 2, rasterA8: UInt16 = 4, topDown: UInt16 = 8 }

/// FIXED28_4: the wire value is the coordinate × 16.
public struct FixedPoint: Sendable, Equatable {
    public var x, y: Int32
    public var cgX: Double { Double(x) / 16 }
    public var cgY: Double { Double(y) / 16 }
    public init(x: Int32, y: Int32) { self.x = x; self.y = y }
    public init(reader r: inout SpiceReader) throws { x = try r.i32(); y = try r.i32() }
}

public struct SpicePathSegment: Sendable, Equatable {
    public var flags: UInt8
    public var points: [FixedPoint]
    public init(flags: UInt8, points: [FixedPoint]) { self.flags = flags; self.points = points }
}

public struct SpicePath: Sendable, Equatable {
    public var segments: [SpicePathSegment]
    public init(segments: [SpicePathSegment]) { self.segments = segments }
    public init(reader r: inout SpiceReader) throws {
        let n = try r.u32()
        guard n <= 1 << 16 else { throw WireError.badValue(field: "num_segments", value: UInt64(n)) }
        segments = try (0 ..< n).map { _ in
            let flags = try r.u8()
            let count = try r.u32()
            guard count <= 1 << 16 else { throw WireError.badValue(field: "seg_count", value: UInt64(count)) }
            return SpicePathSegment(flags: flags, points: try (0 ..< count).map { _ in try FixedPoint(reader: &r) })
        }
    }
}

public struct SpiceLineAttr: Sendable, Equatable {
    public var flags: UInt8
    public init(flags: UInt8) { self.flags = flags }
    /// The styled dash array is parsed for reader position but discarded: QXL strokes solid lines.
    public init(reader r: inout SpiceReader) throws {
        flags = try r.u8()
        if flags & 8 != 0 { _ = try r.u8(); _ = try r.u32() }   // style_nseg, style ptr
    }
}

public struct RasterGlyph: Sendable, Equatable {
    public var renderPos: SpicePoint, origin: SpicePoint
    public var width, height: UInt16
    public var data: [UInt8]
    public init(renderPos: SpicePoint, origin: SpicePoint, width: UInt16, height: UInt16, data: [UInt8]) {
        self.renderPos = renderPos; self.origin = origin; self.width = width; self.height = height; self.data = data
    }
}

public struct SpiceString: Sendable, Equatable {
    public var flags: UInt16
    public var glyphs: [RasterGlyph]
    public var bitsPerPixel: Int { flags & StringFlags.rasterA8 != 0 ? 8 : flags & StringFlags.rasterA4 != 0 ? 4 : 1 }
    public init(flags: UInt16, glyphs: [RasterGlyph]) { self.flags = flags; self.glyphs = glyphs }
    public init(reader r: inout SpiceReader) throws {
        let length = try r.u16()
        flags = UInt16(try r.u8())
        let bpp = flags & StringFlags.rasterA8 != 0 ? 8 : flags & StringFlags.rasterA4 != 0 ? 4 : 1
        glyphs = try (0 ..< length).map { _ in
            let renderPos = try SpicePoint(reader: &r), origin = try SpicePoint(reader: &r)
            let w = try r.u16(), h = try r.u16()
            let rowBytes = (Int(w) * bpp + 7) / 8
            let size = rowBytes * Int(h)
            guard size <= 1 << 20 else { throw WireError.badValue(field: "glyph_size", value: UInt64(size)) }
            return RasterGlyph(renderPos: renderPos, origin: origin, width: w, height: h, data: try r.bytes(size))
        }
    }
}

public enum SpiceBrush: Sendable, Equatable {
    case none
    case solid(UInt32)
    case pattern(SpiceImage, SpicePoint)
    public init(reader r: inout SpiceReader, base: SpiceReader) throws {
        switch try r.u8() {
        case 0: self = .none
        case 1: self = .solid(try r.u32())
        case 2:
            let ptr = try r.u32(); let pos = try SpicePoint(reader: &r)
            guard let img = try SpiceImage.at(pointer: ptr, base: base) else { throw WireError.badValue(field: "pattern", value: 0) }
            self = .pattern(img, pos)
        case let t: throw WireError.badValue(field: "brush_type", value: UInt64(t))
        }
    }
}
