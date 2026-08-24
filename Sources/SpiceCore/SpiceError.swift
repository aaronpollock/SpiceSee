import SpiceWire

public struct SpiceError: Error, Sendable {
    public enum Kind: Sendable {
        case connect, tls, link(LinkError), auth, protocolError(WireError), closed, unsupported(String)
    }
    public var kind: Kind
    public var channel: ChannelDescriptor?
    public var underlying: String?
    public init(_ kind: Kind, channel: ChannelDescriptor? = nil, underlying: String? = nil) {
        self.kind = kind; self.channel = channel; self.underlying = underlying
    }
}
