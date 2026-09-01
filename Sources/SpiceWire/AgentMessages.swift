/// The VD agent protocol (`spice/vd_agent.h`), carried inside `MAIN_AGENT_DATA` on the main channel.
///
/// The server relays this byte stream verbatim between the client and the guest's vdagent. The
/// `VDIChunkHeader` in that header belongs to the virtio side and never appears here; what does
/// appear is a bare `VDAgentMessage` stream, split across `MAIN_AGENT_DATA` messages on arbitrary
/// boundaries.
public enum VDAgent {
    public static let version: UInt32 = 1
    /// `VD_AGENT_MAX_DATA_SIZE` — the most one `MAIN_AGENT_DATA` may carry, header included.
    public static let maxChunk = 2048
    /// `sizeof(VDAgentMessage)`: protocol, type, opaque, size. The struct is `SPICE_ATTR_PACKED`,
    /// so this is 20 and not the 24 that natural alignment of the `uint64` would give.
    public static let headerSize = 20
    /// `VD_AGENT_CAPS_SIZE` for `VD_AGENT_END_CAP` = 18.
    public static let capsWords = 1
    /// Nothing in the protocol bounds `VDAgentMessage.size`, so a hostile server could name an
    /// arbitrary allocation. spice-gtk's default clipboard ceiling is 100 MB; refuse anything past it.
    public static let maxMessageSize = 100 << 20
}

public enum AgentMsgType: UInt32, Sendable {
    case mouseState = 1, monitorsConfig, reply, clipboard, displayConfig, announceCapabilities
    case clipboardGrab, clipboardRequest, clipboardRelease
    case fileXferStart, fileXferStatus, fileXferData, clientDisconnected, maxClipboard
    case audioVolumeSync, graphicsDeviceInfo
}

public enum AgentCap {
    public static let mouseState: UInt32 = 0, monitorsConfig: UInt32 = 1, reply: UInt32 = 2
    public static let clipboard: UInt32 = 3, displayConfig: UInt32 = 4
    public static let clipboardByDemand: UInt32 = 5, clipboardSelection: UInt32 = 6
    public static let sparseMonitorsConfig: UInt32 = 7
    public static let guestLineEndLF: UInt32 = 8, guestLineEndCRLF: UInt32 = 9
    public static let maxClipboard: UInt32 = 10, audioVolumeSync: UInt32 = 11
    public static let monitorsConfigPosition: UInt32 = 12
    public static let fileXferDisabled: UInt32 = 13, fileXferDetailedErrors: UInt32 = 14
    public static let graphicsDeviceInfo: UInt32 = 15
    public static let clipboardNoReleaseOnRegrab: UInt32 = 16, clipboardGrabSerial: UInt32 = 17
}

/// `VD_AGENT_CLIPBOARD_*`. Wire value 0 (`NONE`) is deliberately absent: it means "no type", which
/// Swift expresses as `nil` from `init(rawValue:)`.
public enum ClipboardType: UInt32, Sendable, Equatable {
    case utf8Text = 1, imagePNG, imageBMP, imageTIFF, imageJPG, fileList
}

public enum ClipboardSelection: UInt8, Sendable, Equatable {
    case clipboard = 0, primary, secondary
}

/// One reassembled agent message: its type and the bytes after the 24-byte header.
public struct AgentFrame: Sendable, Equatable {
    public var type: UInt32
    public var payload: [UInt8]
    public init(type: UInt32, payload: [UInt8]) { self.type = type; self.payload = payload }
}

/// `VDAgentMonConfig` — one requested guest monitor. All zeros = a disabled head (sparse config).
public struct AgentMonitorConfig: Sendable, Equatable {
    public var width: UInt32, height: UInt32, depth: UInt32
    public var x: Int32, y: Int32
    public init(width: UInt32, height: UInt32, depth: UInt32 = 32, x: Int32 = 0, y: Int32 = 0) {
        self.width = width; self.height = height; self.depth = depth; self.x = x; self.y = y
    }
}

public enum AgentMonitorsFlags {
    /// `VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS`
    public static let usePosition: UInt32 = 1 << 0
}

public enum AgentMessage: Sendable, Equatable {
    case announceCapabilities(request: Bool, caps: CapabilitySet)
    case clipboardGrab(ClipboardSelection, [ClipboardType])
    case clipboardRequest(ClipboardSelection, ClipboardType)
    case clipboard(ClipboardSelection, ClipboardType, [UInt8])
    case clipboardRelease(ClipboardSelection)
    /// Client → guest only; the guest never sends this type back, so there is no decoder for it.
    case monitorsConfig(flags: UInt32, monitors: [AgentMonitorConfig])
    case other(AgentFrame)

    /// `hasSelection` is the *agent's* `VD_AGENT_CAP_CLIPBOARD_SELECTION`, not ours: the side that
    /// owns the clipboard decides whether the four-byte selection prefix is on the wire, and
    /// spice-gtk reads and writes it on that basis.
    public init(frame: AgentFrame, hasSelection: Bool) throws {
        var r = SpiceReader(frame.payload)
        // Fail soft on a missing prefix rather than dropping the message: the field has three valid
        // values and no bearing on how much else is read, and CLIPBOARD_RELEASE legitimately carries
        // nothing at all when the peer has not negotiated selections.
        func selection() throws -> ClipboardSelection {
            guard hasSelection, r.remaining >= 4 else { return .clipboard }
            let s = try r.u8()
            try r.skip(3)
            return ClipboardSelection(rawValue: s) ?? .clipboard
        }
        switch AgentMsgType(rawValue: frame.type) {
        case .announceCapabilities:
            let request = try r.u32() != 0
            var words: [UInt32] = []
            while r.remaining >= 4 { words.append(try r.u32()) }
            self = .announceCapabilities(request: request, caps: CapabilitySet(words: words))
        case .clipboardGrab:
            let sel = try selection()
            var types: [ClipboardType] = []
            while r.remaining >= 4 {
                if let t = ClipboardType(rawValue: try r.u32()) { types.append(t) }
            }
            self = .clipboardGrab(sel, types)
        case .clipboardRequest:
            let sel = try selection()
            guard let t = ClipboardType(rawValue: try r.u32()) else { self = .other(frame); return }
            self = .clipboardRequest(sel, t)
        case .clipboard:
            let sel = try selection()
            guard let t = ClipboardType(rawValue: try r.u32()) else { self = .other(frame); return }
            self = .clipboard(sel, t, try r.bytes(r.remaining))
        case .clipboardRelease:
            self = .clipboardRelease(try selection())
        default:
            self = .other(frame)
        }
    }

    public func frame(hasSelection: Bool) -> AgentFrame {
        var w = SpiceWriter()
        func put(_ s: ClipboardSelection) {
            guard hasSelection else { return }
            w.u8(s.rawValue); w.u8(0); w.u8(0); w.u8(0)
        }
        switch self {
        case let .announceCapabilities(request, caps):
            w.u32(request ? 1 : 0)
            // The agent sizes its copy from the message length, so send the full word count the
            // protocol defines rather than only the words we happened to set.
            var words = caps.words
            while words.count < VDAgent.capsWords { words.append(0) }
            words.forEach { w.u32($0) }
            return AgentFrame(type: AgentMsgType.announceCapabilities.rawValue, payload: w.bytes)
        case let .clipboardGrab(sel, types):
            put(sel)
            types.forEach { w.u32($0.rawValue) }
            return AgentFrame(type: AgentMsgType.clipboardGrab.rawValue, payload: w.bytes)
        case let .clipboardRequest(sel, type):
            put(sel); w.u32(type.rawValue)
            return AgentFrame(type: AgentMsgType.clipboardRequest.rawValue, payload: w.bytes)
        case let .clipboard(sel, type, data):
            put(sel); w.u32(type.rawValue); w.bytes(data)
            return AgentFrame(type: AgentMsgType.clipboard.rawValue, payload: w.bytes)
        case let .clipboardRelease(sel):
            put(sel)
            return AgentFrame(type: AgentMsgType.clipboardRelease.rawValue, payload: w.bytes)
        case let .monitorsConfig(flags, monitors):
            w.u32(UInt32(monitors.count)); w.u32(flags)
            // VDAgentMonConfig is height-first — pinned against the packed C struct in agentref.
            for m in monitors { w.u32(m.height); w.u32(m.width); w.u32(m.depth); w.i32(m.x); w.i32(m.y) }
            return AgentFrame(type: AgentMsgType.monitorsConfig.rawValue, payload: w.bytes)
        case let .other(frame):
            return frame
        }
    }

    /// Splits a frame into `MAIN_AGENT_DATA` payloads. The header and body are one stream cut every
    /// `VD_AGENT_MAX_DATA_SIZE` bytes — which is what spice-gtk's `agent_msg_queue_many` produces —
    /// and each chunk costs one agent token.
    public static func chunks(_ frame: AgentFrame) -> [[UInt8]] {
        var w = SpiceWriter()
        w.u32(VDAgent.version); w.u32(frame.type); w.u64(0); w.u32(UInt32(frame.payload.count))
        let stream = w.bytes + frame.payload
        return stride(from: 0, to: stream.count, by: VDAgent.maxChunk).map {
            Array(stream[$0 ..< min($0 + VDAgent.maxChunk, stream.count)])
        }
    }
}

/// Rebuilds agent messages from the `MAIN_AGENT_DATA` stream.
///
/// One message may span several `MAIN_AGENT_DATA`, and one `MAIN_AGENT_DATA` may carry the tail of
/// one message and the head of the next, so this is a byte-stream accumulator rather than a
/// per-message decoder. Both length fields it trusts — the header's and the caller's — are the
/// server's, so both are bounds-checked here.
public struct AgentReassembler: Sendable {
    private var header: [UInt8] = []
    private var body: [UInt8] = []
    private var expected = 0
    private var type: UInt32 = 0

    public init() {}

    public mutating func push(_ bytes: [UInt8]) throws -> [AgentFrame] {
        var out: [AgentFrame] = []
        var i = 0
        while i < bytes.count {
            if header.count < VDAgent.headerSize {
                let n = min(VDAgent.headerSize - header.count, bytes.count - i)
                header.append(contentsOf: bytes[i ..< i + n])
                i += n
                guard header.count == VDAgent.headerSize else { break }
                var r = SpiceReader(header)
                let proto = try r.u32()
                guard proto == VDAgent.version else {
                    throw WireError.badValue(field: "vdagent protocol", value: UInt64(proto))
                }
                type = try r.u32()
                _ = try r.u64()          // opaque
                let size = try r.u32()
                guard size <= UInt32(VDAgent.maxMessageSize) else {
                    throw WireError.badValue(field: "vdagent size", value: UInt64(size))
                }
                expected = Int(size)
                body.reserveCapacity(expected)
            }
            let n = min(expected - body.count, bytes.count - i)
            if n > 0 {
                body.append(contentsOf: bytes[i ..< i + n])
                i += n
            }
            guard body.count == expected else { continue }
            out.append(AgentFrame(type: type, payload: body))
            header.removeAll(keepingCapacity: true)
            body.removeAll(keepingCapacity: true)
            expected = 0
        }
        return out
    }
}
