public struct SpiceWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    private mutating func store<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
    }
    public mutating func u8(_ v: UInt8) { store(v) }
    public mutating func u16(_ v: UInt16) { store(v) }
    public mutating func u32(_ v: UInt32) { store(v) }
    public mutating func u64(_ v: UInt64) { store(v) }
    public mutating func i32(_ v: Int32) { store(v) }
    public mutating func bytes(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    public mutating func patchU32(at index: Int, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { src in
            for i in 0 ..< 4 { bytes[index + i] = src[i] }
        }
    }
}
