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
