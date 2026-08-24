public enum CursorServerMsg: UInt16, Sendable {
    case `init` = 101, reset, set, move, hide, trail, invalOne, invalAll
}
public enum CursorFlags { public static let none: UInt16 = 1, cacheMe: UInt16 = 2, fromCache: UInt16 = 4 }
public enum CursorType: UInt8, Sendable { case alpha = 0, mono, color4, color8, color16, color24, color32 }

public struct SpicePoint16: Sendable, Equatable {
    public var x: Int16, y: Int16
    public init(x: Int16, y: Int16) { self.x = x; self.y = y }
    public init(reader r: inout SpiceReader) throws {
        x = Int16(bitPattern: try r.u16()); y = Int16(bitPattern: try r.u16())
    }
}

public struct CursorHeader: Sendable, Equatable {
    public var unique: UInt64, type: CursorType, width: UInt16, height: UInt16, hotX: UInt16, hotY: UInt16
    public static let maxDimension: UInt16 = 1024
    public init(unique: UInt64, type: CursorType, width: UInt16, height: UInt16, hotX: UInt16, hotY: UInt16) {
        self.unique = unique; self.type = type; self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY
    }
    public init(reader r: inout SpiceReader) throws {
        unique = try r.u64()
        let t = try r.u8()
        guard let type = CursorType(rawValue: t) else { throw WireError.badValue(field: "cursor_type", value: UInt64(t)) }
        self.type = type
        width = try r.u16(); height = try r.u16(); hotX = try r.u16(); hotY = try r.u16()
        guard width <= Self.maxDimension, height <= Self.maxDimension else {
            throw WireError.badValue(field: "cursor_size", value: UInt64(width) << 16 | UInt64(height))
        }
    }
}

/// `header`/`data` are absent when `flags` has NONE; FROM_CACHE carries a header and no data.
/// `data` runs to the end of the message (`@end` in spice.proto) — its meaning depends on `header.type`.
public struct SpiceCursor: Sendable, Equatable {
    public var flags: UInt16
    public var header: CursorHeader?
    public var data: [UInt8]
    public init(flags: UInt16, header: CursorHeader?, data: [UInt8]) { self.flags = flags; self.header = header; self.data = data }
    public init(reader r: inout SpiceReader) throws {
        flags = try r.u16()
        guard flags & CursorFlags.none == 0 else { header = nil; data = []; return }
        header = try CursorHeader(reader: &r)
        data = try r.bytes(r.remaining)
    }
}

public enum CursorMessage: Sendable, Equatable {
    case `init`(position: SpicePoint16, visible: Bool, cursor: SpiceCursor)
    case reset
    case set(position: SpicePoint16, visible: Bool, cursor: SpiceCursor)
    case move(SpicePoint16)
    case hide
    case trail(length: UInt16, frequency: UInt16)
    case invalOne(UInt64)
    case invalAll
    case other(type: UInt16)

    public init(type: UInt16, payload: [UInt8]) throws {
        var r = SpiceReader(payload)
        switch CursorServerMsg(rawValue: type) {
        case .`init`:
            let p = try SpicePoint16(reader: &r)
            _ = try r.u16(); _ = try r.u16()            // trail length / frequency: not rendered
            let visible = try r.u8() != 0
            self = .`init`(position: p, visible: visible, cursor: try SpiceCursor(reader: &r))
        case .reset: self = .reset
        case .set:
            let p = try SpicePoint16(reader: &r)
            let visible = try r.u8() != 0
            self = .set(position: p, visible: visible, cursor: try SpiceCursor(reader: &r))
        case .move: self = .move(try SpicePoint16(reader: &r))
        case .hide: self = .hide
        case .trail: self = .trail(length: try r.u16(), frequency: try r.u16())
        case .invalOne: self = .invalOne(try r.u64())
        case .invalAll: self = .invalAll
        case nil: self = .other(type: type)
        }
    }
}
