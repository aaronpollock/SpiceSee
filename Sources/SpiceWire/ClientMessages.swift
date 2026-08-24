public enum ClientMessage {
    public static func frame(type: UInt16, payload: [UInt8], mini: Bool, serial: UInt64) -> [UInt8] {
        DataHeader(serial: serial, type: type, size: UInt32(payload.count), subList: 0).encode(mini: mini) + payload
    }
    public static func ackSync(generation: UInt32) -> [UInt8] { var w = SpiceWriter(); w.u32(generation); return w.bytes }
    public static func ack() -> [UInt8] { [] }
    public static func pong(_ p: Ping) -> [UInt8] { var w = SpiceWriter(); w.u32(p.id); w.u64(p.timestamp); return w.bytes }
    public static func attachChannels() -> [UInt8] { [] }
    public static func mouseModeRequest(_ mode: UInt32) -> [UInt8] { var w = SpiceWriter(); w.u32(mode); return w.bytes }
}
