public struct SpiceLinkMess: Sendable {
    public var connectionID: UInt32
    public var channelType: ChannelType
    public var channelID: UInt8
    public var commonCaps: CapabilitySet
    public var channelCaps: CapabilitySet

    public init(connectionID: UInt32, channelType: ChannelType, channelID: UInt8,
                commonCaps: CapabilitySet, channelCaps: CapabilitySet) {
        self.connectionID = connectionID; self.channelType = channelType; self.channelID = channelID
        self.commonCaps = commonCaps; self.channelCaps = channelCaps
    }

    /// SpiceLinkHeader + SpiceLinkMess + caps words.
    public func encode() -> [UInt8] {
        var w = SpiceWriter()
        w.u32(Link.magic); w.u32(Link.major); w.u32(Link.minor); w.u32(0)
        w.u32(connectionID)
        w.u8(channelType.rawValue); w.u8(channelID)
        w.u32(UInt32(commonCaps.words.count)); w.u32(UInt32(channelCaps.words.count))
        w.u32(18) // caps_offset: sizeof(SpiceLinkMess)
        commonCaps.words.forEach { w.u32($0) }
        channelCaps.words.forEach { w.u32($0) }
        w.patchU32(at: 12, UInt32(w.bytes.count - 16))
        return w.bytes
    }
}

public struct SpiceLinkReply: Sendable, Equatable {
    public var error: LinkError
    public var publicKey: [UInt8]
    public var commonCaps: CapabilitySet
    public var channelCaps: CapabilitySet

    /// Reads the 16-byte SpiceLinkHeader, returns the size of the reply body that follows.
    public static func parseHeader(_ r: inout SpiceReader) throws -> Int {
        let magic = try r.u32()
        guard magic == Link.magic else { throw WireError.badValue(field: "magic", value: UInt64(magic)) }
        let major = try r.u32()
        guard major == Link.major else { throw WireError.badValue(field: "major", value: UInt64(major)) }
        _ = try r.u32() // minor
        let size = try r.u32()
        guard size >= 178, size < 1 << 16 else { throw WireError.badValue(field: "size", value: UInt64(size)) }
        return Int(size)
    }

    /// Parses the reply body (reader positioned right after the header).
    public init(reader r: inout SpiceReader) throws {
        var body = try r.reader(at: UInt32(r.offset))
        let err = try body.u32()
        guard let e = LinkError(rawValue: err) else { throw WireError.badValue(field: "error", value: UInt64(err)) }
        error = e
        publicKey = try body.bytes(Link.ticketPubkeyBytes)
        let nCommon = try body.u32(), nChannel = try body.u32(), capsOffset = try body.u32()
        guard nCommon <= 16, nChannel <= 16 else { throw WireError.badValue(field: "num_caps", value: UInt64(nCommon)) }
        var caps = try body.reader(at: capsOffset)
        commonCaps = CapabilitySet(words: try (0 ..< nCommon).map { _ in try caps.u32() })
        channelCaps = CapabilitySet(words: try (0 ..< nChannel).map { _ in try caps.u32() })
        try r.skip(caps.offset - r.offset)  // consume the whole body
    }
}
