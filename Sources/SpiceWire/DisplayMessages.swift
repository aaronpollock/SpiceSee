public enum DisplayServerMsg: UInt16, Sendable {
    case mode = 101, mark, reset, copyBits, invalList, invalAllPixmaps, invalPalette, invalAllPalettes
    case streamCreate = 122, streamData, streamClip, streamDestroy, streamDestroyAll
    case drawFill = 302, drawOpaque, drawCopy, drawBlend, drawBlackness, drawWhiteness, drawInvers
    case drawRop3, drawStroke, drawText, drawTransparent, drawAlphaBlend, surfaceCreate, surfaceDestroy
    case streamDataSized, monitorsConfig, drawComposite, streamActivateReport
}
public enum DisplayClientMsg: UInt16, Sendable {
    case `init` = 101, streamReport, preferredCompression, glDrawDone, preferredVideoCodecType
}
public enum SurfaceFormat: UInt32, Sendable { case a1 = 1, a8 = 8, rgb555 = 16, xrgb32 = 32, rgb565 = 80, argb32 = 96 }

public struct SurfaceCreate: Sendable, Equatable {
    public var surfaceID: UInt32, width: UInt32, height: UInt32, format: SurfaceFormat, flags: UInt32
    public var isPrimary: Bool { flags & 1 != 0 }
    public init(reader r: inout SpiceReader) throws {
        surfaceID = try r.u32(); width = try r.u32(); height = try r.u32()
        let f = try r.u32()
        guard let fmt = SurfaceFormat(rawValue: f) else { throw WireError.badValue(field: "surface_format", value: UInt64(f)) }
        format = fmt; flags = try r.u32()
        guard width <= 16384, height <= 16384 else { throw WireError.badValue(field: "surface_size", value: UInt64(width)) }
    }
}

public struct DrawBase: Sendable, Equatable {
    public var surfaceID: UInt32, box: SpiceRect, clip: SpiceClip
    public init(reader r: inout SpiceReader) throws {
        surfaceID = try r.u32(); box = try SpiceRect(reader: &r); clip = try SpiceClip(reader: &r)
    }
}

public struct DrawFill: Sendable, Equatable {
    public var base: DrawBase, brush: SpiceBrush, rop: UInt16, mask: SpiceQMask
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r); brush = try SpiceBrush(reader: &r, base: body)
        rop = try r.u16(); mask = try SpiceQMask(reader: &r, base: body)
    }
}

public struct DrawCopy: Sendable, Equatable {
    public var base: DrawBase, source: SpiceImage?, sourceArea: SpiceRect, rop: UInt16, scaleMode: UInt8, mask: SpiceQMask
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r)
        source = try SpiceImage.at(pointer: try r.u32(), base: body)
        sourceArea = try SpiceRect(reader: &r); rop = try r.u16(); scaleMode = try r.u8()
        mask = try SpiceQMask(reader: &r, base: body)
    }
}

public struct DrawOpaque: Sendable, Equatable {
    public var base: DrawBase, source: SpiceImage?, sourceArea: SpiceRect, brush: SpiceBrush, rop: UInt16, scaleMode: UInt8, mask: SpiceQMask
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r)
        source = try SpiceImage.at(pointer: try r.u32(), base: body)
        sourceArea = try SpiceRect(reader: &r); brush = try SpiceBrush(reader: &r, base: body)
        rop = try r.u16(); scaleMode = try r.u8(); mask = try SpiceQMask(reader: &r, base: body)
    }
}

public struct DrawMaskOnly: Sendable, Equatable {
    public var base: DrawBase, mask: SpiceQMask
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r); mask = try SpiceQMask(reader: &r, base: body)
    }
}

public struct CopyBits: Sendable, Equatable {
    public var base: DrawBase, sourcePos: SpicePoint
    init(reader r: inout SpiceReader) throws { base = try DrawBase(reader: &r); sourcePos = try SpicePoint(reader: &r) }
}

public struct DrawAlphaBlend: Sendable, Equatable {
    public var base: DrawBase, alphaFlags: UInt8, alpha: UInt8, source: SpiceImage?, sourceArea: SpiceRect
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r); alphaFlags = try r.u8(); alpha = try r.u8()
        source = try SpiceImage.at(pointer: try r.u32(), base: body); sourceArea = try SpiceRect(reader: &r)
    }
}

public struct MonitorHead: Sendable, Equatable {
    public var id, surfaceID, width, height, x, y, flags: UInt32
    init(reader r: inout SpiceReader) throws {
        id = try r.u32(); surfaceID = try r.u32(); width = try r.u32(); height = try r.u32()
        x = try r.u32(); y = try r.u32(); flags = try r.u32()
    }
}
public struct MonitorsConfig: Sendable, Equatable {
    public var maxAllowed: UInt16, heads: [MonitorHead]
    init(reader r: inout SpiceReader) throws {
        let count = try r.u16(); maxAllowed = try r.u16()
        guard count <= 64 else { throw WireError.badValue(field: "monitor_count", value: UInt64(count)) }
        heads = try (0 ..< count).map { _ in try MonitorHead(reader: &r) }
    }
}
public struct ResourceID: Sendable, Equatable { public var type: UInt8, id: UInt64 }

public enum DisplayMessage: Sendable {
    case mode(width: UInt32, height: UInt32, bits: UInt32)
    case mark, reset
    case surfaceCreate(SurfaceCreate), surfaceDestroy(UInt32)
    case fill(DrawFill), copy(DrawCopy), blend(DrawCopy), opaque(DrawOpaque)
    case blackness(DrawMaskOnly), whiteness(DrawMaskOnly), invers(DrawMaskOnly)
    case copyBits(CopyBits), alphaBlend(DrawAlphaBlend)
    case invalList([ResourceID]), invalAllPixmaps, invalPalette(UInt64), invalAllPalettes
    case monitorsConfig(MonitorsConfig)
    case unsupported(type: UInt16, payload: [UInt8])

    public init(type: UInt16, payload: [UInt8]) throws {
        let body = SpiceReader(payload)
        var r = body
        switch DisplayServerMsg(rawValue: type) {
        case .mode: self = .mode(width: try r.u32(), height: try r.u32(), bits: try r.u32())
        case .mark: self = .mark
        case .reset: self = .reset
        case .surfaceCreate: self = .surfaceCreate(try SurfaceCreate(reader: &r))
        case .surfaceDestroy: self = .surfaceDestroy(try r.u32())
        case .drawFill: self = .fill(try DrawFill(reader: &r, body: body))
        case .drawCopy: self = .copy(try DrawCopy(reader: &r, body: body))
        case .drawBlend: self = .blend(try DrawCopy(reader: &r, body: body))
        case .drawOpaque: self = .opaque(try DrawOpaque(reader: &r, body: body))
        case .drawBlackness: self = .blackness(try DrawMaskOnly(reader: &r, body: body))
        case .drawWhiteness: self = .whiteness(try DrawMaskOnly(reader: &r, body: body))
        case .drawInvers: self = .invers(try DrawMaskOnly(reader: &r, body: body))
        case .copyBits: self = .copyBits(try CopyBits(reader: &r))
        case .drawAlphaBlend: self = .alphaBlend(try DrawAlphaBlend(reader: &r, body: body))
        case .invalList:
            let n = try r.u16()
            self = .invalList(try (0 ..< n).map { _ in ResourceID(type: try r.u8(), id: try r.u64()) })
        case .invalAllPixmaps: self = .invalAllPixmaps
        case .invalPalette: self = .invalPalette(try r.u64())
        case .invalAllPalettes: self = .invalAllPalettes
        case .monitorsConfig: self = .monitorsConfig(try MonitorsConfig(reader: &r))
        default: self = .unsupported(type: type, payload: payload)
        }
    }
}
