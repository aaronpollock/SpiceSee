public struct SpiceReader: Sendable {
    private let storage: [UInt8]
    private let base: Int
    public private(set) var offset: Int

    public init(_ bytes: [UInt8]) { storage = bytes; base = 0; offset = 0 }
    private init(storage: [UInt8], base: Int) { self.storage = storage; self.base = base; offset = base }

    public var count: Int { storage.count - base }
    public var remaining: Int { storage.count - offset }

    private mutating func load<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { throw WireError.truncated(needed: n, available: remaining) }
        let v = storage.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += n
        return T(littleEndian: v)
    }
    public mutating func u8() throws -> UInt8 { try load(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try load(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try load(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try load(UInt64.self) }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try load(UInt32.self)) }

    public mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw WireError.truncated(needed: n, available: remaining) }
        defer { offset += n }
        return Array(storage[offset ..< offset + n])
    }
    public mutating func skip(_ n: Int) throws { _ = try bytes(n) }

    /// A reader positioned at `pointer` bytes from this reader's base (SPICE pointer fields).
    public func reader(at pointer: UInt32) throws -> SpiceReader {
        let abs = base + Int(pointer)
        guard abs <= storage.count else { throw WireError.badOffset(Int(pointer)) }
        return SpiceReader(storage: storage, base: abs)
    }
}
