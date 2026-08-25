public enum MainServerMsg: UInt16, Sendable {
    case migrateBegin = 101, migrateCancel, `init`, channelsList, mouseMode, multiMediaTime
    case agentConnected, agentDisconnected, agentData, agentToken, migrateSwitchHost, migrateEnd
    case name, uuid, agentConnectedTokens, migrateBeginSeamless, migrateDstSeamlessAck, migrateDstSeamlessNack
}
public enum MainClientMsg: UInt16, Sendable {
    case clientInfo = 101, migrateConnected, migrateConnectError, attachChannels, mouseModeRequest
    case agentStart, agentData, agentToken, migrateEnd, migrateDstDoSeamless
}

public struct MainInit: Sendable, Equatable {
    public var sessionID, displayChannelsHint, supportedMouseModes, currentMouseMode: UInt32
    public var agentConnected, agentTokens, multiMediaTime, ramHint: UInt32
    public init(reader r: inout SpiceReader) throws {
        sessionID = try r.u32(); displayChannelsHint = try r.u32()
        supportedMouseModes = try r.u32(); currentMouseMode = try r.u32()
        agentConnected = try r.u32(); agentTokens = try r.u32()
        multiMediaTime = try r.u32(); ramHint = try r.u32()
    }
}

public struct ChannelDescriptor: Sendable, Hashable {
    public var type: ChannelType, id: UInt8
    public init(type: ChannelType, id: UInt8) { self.type = type; self.id = id }
}

public struct ChannelsList: Sendable, Equatable {
    public var channels: [ChannelDescriptor]
    public init(reader r: inout SpiceReader) throws {
        let n = try r.u32()
        guard n <= 256 else { throw WireError.badValue(field: "num_of_channels", value: UInt64(n)) }
        channels = []
        for _ in 0 ..< n {
            let t = try r.u8(), id = try r.u8()
            if let type = ChannelType(rawValue: t) { channels.append(ChannelDescriptor(type: type, id: id)) }
        }
    }
}

public struct MouseMode: Sendable, Equatable {
    public var supported: UInt32, current: UInt32
    public init(reader r: inout SpiceReader) throws { supported = try r.u32(); current = try r.u32() }
}

public struct MultiMediaTime: Sendable, Equatable {
    public var time: UInt32
    public init(reader r: inout SpiceReader) throws { time = try r.u32() }
}

/// Where the cluster moved this VM. `spice.proto` gives both a plain and a TLS port; either may be
/// absent (0, or 0xFFFFFFFF from older servers).
public struct MigrationTarget: Sendable, Equatable {
    public var host: String
    public var port: UInt16?
    public var tlsPort: UInt16?
    public var certSubject: String?
    public init(host: String, port: UInt16?, tlsPort: UInt16?, certSubject: String?) {
        self.host = host; self.port = port; self.tlsPort = tlsPort; self.certSubject = certSubject
    }

    /// Longest string we will take from a migration message. Hostnames and subjects are far shorter;
    /// the cap exists so a bad length cannot make us allocate.
    static let maxStringBytes = 4096

    /// The six-word header is followed by the pointed-to bytes. Every offset and size is checked
    /// against the payload before it is used — this message arrives from the server mid-session and
    /// a bad one must be a caught error, never a trap.
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        let plain = try r.u32(), secure = try r.u32()
        let hostSize = try r.u32(), hostOffset = try r.u32()
        let subjectSize = try r.u32(), subjectOffset = try r.u32()

        func string(size: UInt32, offset: UInt32, field: String) throws -> String? {
            guard size > 0 else { return nil }
            guard size <= UInt32(Self.maxStringBytes) else {
                throw WireError.badValue(field: "\(field)_size", value: UInt64(size))
            }
            var at = try body.reader(at: offset)
            let bytes = try at.bytes(Int(size))
            guard let nul = bytes.firstIndex(of: 0) else {
                throw WireError.badValue(field: "\(field)_terminator", value: UInt64(size))
            }
            return String(decoding: bytes[..<nul], as: UTF8.self)
        }

        guard let host = try string(size: hostSize, offset: hostOffset, field: "host"), !host.isEmpty else {
            throw WireError.badValue(field: "migration_host", value: UInt64(hostSize))
        }
        self.host = host
        certSubject = try string(size: subjectSize, offset: subjectOffset, field: "cert_subject")
        port = Self.port(plain)
        tlsPort = Self.port(secure)
    }

    private static func port(_ value: UInt32) -> UInt16? {
        guard value > 0, value <= UInt32(UInt16.max) else { return nil }
        return UInt16(value)
    }
}

public enum MainMessage: Sendable {
    case `init`(MainInit)
    case channelsList(ChannelsList)
    case mouseMode(MouseMode)
    case multiMediaTime(MultiMediaTime)
    case agentConnected
    case agentDisconnected(UInt32)
    case agentData([UInt8])
    case agentToken(UInt32)
    case agentConnectedTokens(UInt32)
    case name(String)
    case uuid([UInt8])
    case migrateBegin(MigrationTarget)
    case migrateSwitchHost(MigrationTarget)
    case migrateCancel
    case migrateEnd
    case other(type: UInt16, payload: [UInt8])

    public init(type: UInt16, payload: [UInt8]) throws {
        var r = SpiceReader(payload)
        let body = SpiceReader(payload)
        switch MainServerMsg(rawValue: type) {
        case .`init`: self = .`init`(try MainInit(reader: &r))
        case .channelsList: self = .channelsList(try ChannelsList(reader: &r))
        case .mouseMode: self = .mouseMode(try MouseMode(reader: &r))
        case .multiMediaTime: self = .multiMediaTime(try MultiMediaTime(reader: &r))
        case .agentConnected: self = .agentConnected
        case .agentDisconnected: self = .agentDisconnected(try r.u32())
        case .agentData: self = .agentData(payload)
        case .agentToken: self = .agentToken(try r.u32())
        case .agentConnectedTokens: self = .agentConnectedTokens(try r.u32())
        case .name:
            let len = try r.u32()
            self = .name(String(decoding: try r.bytes(Int(min(len, 4096))), as: UTF8.self))
        case .uuid: self = .uuid(try r.bytes(16))
        case .migrateBegin: self = .migrateBegin(try MigrationTarget(reader: &r, body: body))
        case .migrateSwitchHost: self = .migrateSwitchHost(try MigrationTarget(reader: &r, body: body))
        case .migrateCancel: self = .migrateCancel
        case .migrateEnd: self = .migrateEnd
        default: self = .other(type: type, payload: payload)
        }
    }
}
