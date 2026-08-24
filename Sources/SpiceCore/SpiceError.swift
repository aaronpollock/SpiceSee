import SpiceWire

/// Why a TLS connection could not be trusted. `subjectMismatch` carries both subjects because the
/// design's failure sheet shows them — they are certificate facts, not SPICE error codes.
public enum TLSFailure: Error, Sendable, Equatable {
    case handshake(String)
    case untrusted(String)
    case badCertificate(String)
    case subjectMismatch(expected: String, presented: String)
}

public struct SpiceError: Error, Sendable {
    public enum Kind: Sendable {
        case connect, tls(TLSFailure), link(LinkError), auth, protocolError(WireError), closed
        case unsupported(String), vvFile(String)
    }
    public var kind: Kind
    public var channel: ChannelDescriptor?
    public var underlying: String?
    public init(_ kind: Kind, channel: ChannelDescriptor? = nil, underlying: String? = nil) {
        self.kind = kind; self.channel = channel; self.underlying = underlying
    }
}
