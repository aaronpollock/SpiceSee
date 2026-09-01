import os
import SpiceWire

/// One agent message together with the negotiated state as it stood when that message arrived.
///
/// The state is stamped rather than queried back: consumers run in their own task, so by the time
/// one interprets a message the actor may have moved on — a later message can change the
/// capabilities, or drop the agent entirely, and the earlier event would then be read against state
/// it was never true for.
public struct AgentEvent: Sendable {
    public var message: AgentMessage
    public var clipboardReady: Bool
    public var guestWantsCRLF: Bool
}

/// The guest agent's half of the main channel: capability negotiation, token flow control, and
/// reassembly of the `MAIN_AGENT_DATA` stream.
///
/// Driven by `SpiceSession`, which owns the main channel's message stream — this actor never reads
/// the socket itself, it is fed the agent messages that arrive there and hands back chunks to send.
public actor AgentSession {
    /// What the client announces. Clipboard, plus `sparseMonitorsConfig` because our
    /// `VD_AGENT_MONITORS_CONFIG` may carry disabled heads (M5). Still absent on purpose: the
    /// pointer and audio-volume paths, which SpiceSee does not route — announcing a capability it
    /// does not honour would tell the guest to stop using the paths that do work.
    public static let clientCaps = CapabilitySet(bits: [AgentCap.clipboardByDemand,
                                                        AgentCap.clipboardSelection,
                                                        AgentCap.sparseMonitorsConfig])

    public nonisolated let messages: AsyncStream<AgentEvent>
    private let cont: AsyncStream<AgentEvent>.Continuation
    private let send: @Sendable ([UInt8]) async throws -> Void
    private var reassembler = AgentReassembler()
    /// Chunks waiting on a token. `MAIN_AGENT_DATA` is the only client message the server meters.
    private var queue: [[UInt8]] = []
    private var tokens: UInt32 = 0
    private var connected = false
    public private(set) var guestCaps = CapabilitySet()
    public private(set) var capsReceived = false
    private let log = Logger(subsystem: "com.spicesee", category: "agent")

    public init(send: @escaping @Sendable ([UInt8]) async throws -> Void) {
        self.send = send
        (messages, cont) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    /// Whether clipboard messages may be sent: the guest must have said it does clipboard-by-demand.
    public var clipboardReady: Bool { connected && capsReceived && guestCaps.contains(AgentCap.clipboardByDemand) }

    /// Whether a monitors config may be sent: the guest must have announced it applies them.
    public var guestSupportsMonitorsConfig: Bool {
        connected && capsReceived && guestCaps.contains(AgentCap.monitorsConfig)
    }

    /// The guest's line endings, which decide whether text needs converting on the way through.
    public var guestWantsCRLF: Bool { guestCaps.contains(AgentCap.guestLineEndCRLF) }

    /// Whether the four-byte selection prefix is on the wire. The clipboard owner's capability
    /// decides, so this is the guest's bit, not ours.
    private var hasSelection: Bool { guestCaps.contains(AgentCap.clipboardSelection) }

    /// The server's spending allowance for us. `MAIN_INIT` seeds it and
    /// `MAIN_AGENT_CONNECTED_TOKENS` replaces it; a plain `MAIN_AGENT_CONNECTED` leaves it alone,
    /// which is why this is separate from `agentConnected`.
    public func setTokens(_ n: UInt32) async {
        tokens = n
        await flush()
    }

    /// The agent came up (`MAIN_AGENT_CONNECTED`, or `MAIN_INIT` already reporting one).
    public func agentConnected() async {
        connected = true
        capsReceived = false
        guestCaps = CapabilitySet()
        reassembler = AgentReassembler()
        queue.removeAll()
        await enqueue(.announceCapabilities(request: true, caps: Self.clientCaps))
    }

    public func agentDisconnected() {
        connected = false
        capsReceived = false
        guestCaps = CapabilitySet()
        queue.removeAll()
    }

    /// `MAIN_AGENT_TOKEN`: the server granting room for more messages.
    public func credit(_ n: UInt32) async {
        tokens &+= n
        await flush()
    }

    /// One `MAIN_AGENT_DATA` payload from the server.
    public func receive(_ data: [UInt8]) async {
        let frames: [AgentFrame]
        do { frames = try reassembler.push(data) }
        catch {
            // A length the reassembler will not accept has desynchronised the stream; there is no
            // resynchronisation point in it, so drop the agent rather than parse rubbish forever.
            log.error("agent stream: \(String(describing: error)); dropping the agent")
            agentDisconnected()
            return
        }
        for frame in frames {
            guard let m = try? AgentMessage(frame: frame, hasSelection: hasSelection) else {
                log.error("agent: undecodable message type \(frame.type)")
                continue
            }
            if case let .announceCapabilities(request, caps) = m {
                guestCaps = caps
                capsReceived = true
                // `request` means the guest wants ours back; answering an answer would loop.
                if request { await enqueue(.announceCapabilities(request: false, caps: Self.clientCaps)) }
            }
            cont.yield(AgentEvent(message: m, clipboardReady: clipboardReady, guestWantsCRLF: guestWantsCRLF))
        }
    }

    public func send(_ message: AgentMessage) async {
        await enqueue(message)
    }

    private func enqueue(_ message: AgentMessage) async {
        guard connected else { return }
        queue.append(contentsOf: AgentMessage.chunks(message.frame(hasSelection: hasSelection)))
        await flush()
    }

    private func flush() async {
        while tokens > 0, !queue.isEmpty {
            tokens -= 1
            let chunk = queue.removeFirst()
            do { try await send(chunk) }
            catch {
                log.error("agent send failed: \(String(describing: error))")
                queue.removeAll()
                return
            }
        }
    }

    public func finish() { cont.finish() }
}
