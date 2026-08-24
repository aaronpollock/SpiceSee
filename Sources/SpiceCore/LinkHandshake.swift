import SpiceWire

public struct LinkResult: Sendable {
    public var serverCommonCaps: CapabilitySet
    public var serverChannelCaps: CapabilitySet
    public var miniHeader: Bool
}

public enum LinkHandshake {
    public static func clientCommonCaps() -> CapabilitySet {
        CapabilitySet(bits: [CommonCap.authSpice, CommonCap.miniHeader])
    }

    public static func perform(on t: any Transport, connectionID: UInt32, channel: ChannelDescriptor,
                               channelCaps: CapabilitySet, password: String?) async throws -> LinkResult {
        let mess = SpiceLinkMess(connectionID: connectionID, channelType: channel.type, channelID: channel.id,
                                 commonCaps: clientCommonCaps(), channelCaps: channelCaps)
        try await t.write(mess.encode())

        var hdr = SpiceReader(try await t.read(exactly: 16))
        let size: Int
        do { size = try SpiceLinkReply.parseHeader(&hdr) } catch let e as WireError { throw SpiceError(.protocolError(e), channel: channel) }
        var body = SpiceReader(try await t.read(exactly: size))
        let reply: SpiceLinkReply
        do { reply = try SpiceLinkReply(reader: &body) } catch let e as WireError { throw SpiceError(.protocolError(e), channel: channel) }
        guard reply.error == .ok else { throw SpiceError(.link(reply.error), channel: channel) }

        if reply.commonCaps.contains(CommonCap.protocolAuthSelection) {
            var w = SpiceWriter(); w.u32(CommonCap.authSpice)
            try await t.write(w.bytes)
        }
        try await t.write(try Ticket.encrypt(password: password ?? "", publicKey: reply.publicKey))

        var res = SpiceReader(try await t.read(exactly: 4))
        let code = try res.u32()
        guard code == 0 else { throw SpiceError(.link(LinkError(rawValue: code) ?? .error), channel: channel) }

        return LinkResult(serverCommonCaps: reply.commonCaps, serverChannelCaps: reply.channelCaps,
                          miniHeader: reply.commonCaps.contains(CommonCap.miniHeader))
    }
}
