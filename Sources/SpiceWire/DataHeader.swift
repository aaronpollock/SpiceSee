public struct DataHeader: Sendable, Equatable {
    public var serial: UInt64
    public var type: UInt16
    public var size: UInt32
    public var subList: UInt32
    public static let fullSize = 18
    public static let miniSize = 6

    public init(serial: UInt64, type: UInt16, size: UInt32, subList: UInt32) {
        self.serial = serial; self.type = type; self.size = size; self.subList = subList
    }
    public init(mini r: inout SpiceReader) throws {
        serial = 0; type = try r.u16(); size = try r.u32(); subList = 0
    }
    public init(full r: inout SpiceReader) throws {
        serial = try r.u64(); type = try r.u16(); size = try r.u32(); subList = try r.u32()
    }
    public func encode(mini: Bool) -> [UInt8] {
        var w = SpiceWriter()
        if !mini { w.u64(serial) }
        w.u16(type); w.u32(size)
        if !mini { w.u32(subList) }
        return w.bytes
    }
}
