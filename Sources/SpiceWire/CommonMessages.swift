public enum CommonServerMsg: UInt16, Sendable {
    case migrate = 1, migrateData = 2, setAck = 3, ping = 4, waitForChannels = 5
    case disconnecting = 6, notify = 7, list = 8
}
public enum CommonClientMsg: UInt16, Sendable {
    case ackSync = 1, ack = 2, pong = 3, migrateFlushMark = 4, migrateData = 5, disconnecting = 6
}

public struct SetAck: Sendable, Equatable {
    public var generation: UInt32, window: UInt32
    public init(reader r: inout SpiceReader) throws { generation = try r.u32(); window = try r.u32() }
}

public struct Ping: Sendable, Equatable {
    public var id: UInt32, timestamp: UInt64
    public init(id: UInt32, timestamp: UInt64) { self.id = id; self.timestamp = timestamp }
    public init(reader r: inout SpiceReader) throws { id = try r.u32(); timestamp = try r.u64() }
}

public struct Notify: Sendable, Equatable {
    public var timestamp: UInt64, severity: UInt32, visibility: UInt32, what: UInt32, message: String
    public init(reader r: inout SpiceReader) throws {
        timestamp = try r.u64(); severity = try r.u32(); visibility = try r.u32(); what = try r.u32()
        let len = try r.u32()
        guard len < 1 << 16 else { throw WireError.badValue(field: "message_len", value: UInt64(len)) }
        message = String(decoding: try r.bytes(Int(len)), as: UTF8.self)
    }
}
