import Foundation
import Testing
import SpiceCore
import SpiceWire
@testable import SpiceKit

/// Drives the whole agent path — `MAIN_INIT` through capability negotiation, token flow control and
/// both clipboard directions — against a scripted server. `AgentMessagesTests` pins the bytes
/// against the real C structs; these pin the state machine that produces them.
@Suite struct ClipboardSessionTests {
    /// A live main channel: serves `input`, then holds the connection open while recording what the
    /// client wrote. `InMemoryTransport` hits EOF and ends the session before the agent handshake
    /// has finished, which would race every assertion here.
    private actor RecordingTransport: Transport {
        private let input: [UInt8]
        private var cursor = 0
        private var waiters: [CheckedContinuation<[UInt8], Error>] = []
        private(set) var written: [UInt8] = []
        private var closed = false
        init(input: [UInt8]) { self.input = input }

        func read(exactly n: Int) async throws -> [UInt8] {
            guard !closed else { throw SpiceError(.closed, underlying: "closed") }
            if input.count - cursor >= n { defer { cursor += n }; return Array(input[cursor ..< cursor + n]) }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        func write(_ bytes: [UInt8]) { written.append(contentsOf: bytes) }
        func close() {
            closed = true
            waiters.forEach { $0.resume(throwing: SpiceError(.closed, underlying: "closed")) }
            waiters.removeAll()
        }
    }

    private actor Collected {
        private(set) var events: [ClipboardEvent] = []
        func add(_ e: ClipboardEvent) { events.append(e) }
    }

    // MARK: Fixture construction

    /// MAIN_INIT: session 1, one display, client mouse mode, then `agentConnected` / `agentTokens`.
    private func mainInit(agentConnected: Bool, tokens: UInt32) -> [UInt8] {
        var w = SpiceWriter()
        [1, 1, 1, 1].forEach { w.u32(UInt32($0)) }
        w.u32(agentConnected ? 1 : 0); w.u32(tokens)
        w.u32(0); w.u32(0)
        return w.bytes
    }

    /// What the guest agent would send: it does clipboard by demand, uses selections, and — being
    /// Windows — has CRLF line endings.
    private func guestCaps(crlf: Bool = true) -> AgentMessage {
        var bits = [AgentCap.clipboardByDemand, AgentCap.clipboardSelection]
        if crlf { bits.append(AgentCap.guestLineEndCRLF) }
        return .announceCapabilities(request: false, caps: CapabilitySet(bits: bits))
    }

    private func serverAgentData(_ m: AgentMessage, hasSelection: Bool = true) -> [UInt8] {
        AgentMessage.chunks(m.frame(hasSelection: hasSelection))
            .flatMap { frame(MainServerMsg.agentData.rawValue, $0) }
    }

    private func script(agentConnected: Bool = true, tokens: UInt32 = 10, _ messages: [[UInt8]] = []) throws -> [UInt8] {
        var cl = SpiceWriter(); cl.u32(0)
        return try fakeLink(body:
            frame(MainServerMsg.`init`.rawValue, mainInit(agentConnected: agentConnected, tokens: tokens))
            + frame(MainServerMsg.channelsList.rawValue, cl.bytes)
            + messages.flatMap { $0 })
    }

    // MARK: Reading back what the client sent

    private func clientFrames(_ t: RecordingTransport) async throws -> [(type: UInt16, payload: [UInt8])] {
        var r = SpiceReader(await t.written)
        try r.skip(12); let n = Int(try r.u32()); try r.skip(n); try r.skip(Link.ticketBytes)
        var out: [(UInt16, [UInt8])] = []
        while r.remaining >= DataHeader.miniSize {
            let h = try DataHeader(mini: &r)
            out.append((h.type, try r.bytes(Int(h.size))))
        }
        return out
    }

    /// Every MAIN_AGENT_DATA the client sent, reassembled and decoded.
    private func clientAgentMessages(_ t: RecordingTransport, hasSelection: Bool = true) async throws -> [AgentMessage] {
        let chunks = try await clientFrames(t)
            .filter { $0.type == MainClientMsg.agentData.rawValue }
            .flatMap(\.payload)
        var r = AgentReassembler()
        return try r.push(chunks).map { try AgentMessage(frame: $0, hasSelection: hasSelection) }
    }

    private func waitFor(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0 ..< 400 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func open(_ transport: RecordingTransport) async throws -> (SpiceSession, Collected) {
        let session = try await SpiceSession.connect(password: nil) { desc in
            desc.type == .main ? transport : RecordingTransport(input: try fakeLink(body: []))
        }
        let collected = Collected()
        Task { [events = session.events] in
            for await e in events { if case let .clipboard(c) = e { await collected.add(c) } }
        }
        return (session, collected)
    }

    // MARK: Negotiation

    @Test func anAgentAtInitIsStartedAndSentOurCapabilities() async throws {
        let main = RecordingTransport(input: try script())
        let (session, _) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { try await !self.clientAgentMessages(main).isEmpty }

        let starts = try await clientFrames(main).filter { $0.type == MainClientMsg.agentStart.rawValue }
        #expect(starts.map(\.payload) == [ClientMessage.agentStart(tokens: .max)])

        // Our announcement precedes the guest's, so it is written without the selection prefix
        // convention mattering — capabilities never carry one.
        #expect(try await clientAgentMessages(main)
                == [.announceCapabilities(request: true, caps: AgentSession.clientCaps)])
    }

    @Test func noAgentMeansNothingIsSent() async throws {
        let main = RecordingTransport(input: try script(agentConnected: false))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await Task.sleep(for: .milliseconds(60))
        #expect(try await clientFrames(main).filter { $0.type == MainClientMsg.agentStart.rawValue }.isEmpty)
        #expect(await collected.events.isEmpty)
    }

    @Test func theGuestsCapabilitiesMakeClipboardSharingAvailable() async throws {
        let main = RecordingTransport(input: try script(tokens: 10, [serverAgentData(guestCaps(), hasSelection: false)]))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { await collected.events.contains(.available(true)) }
        #expect(await collected.events == [.available(true)])
    }

    /// A guest that announces no clipboard capability must not be treated as sharing-capable, or
    /// every later send would be dropped silently instead of the UI knowing it is off.
    @Test func aGuestWithoutClipboardCapabilityIsNotAvailable() async throws {
        let bare = AgentMessage.announceCapabilities(request: false, caps: CapabilitySet(bits: [AgentCap.mouseState]))
        let main = RecordingTransport(input: try script([serverAgentData(bare, hasSelection: false)]))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { await !collected.events.isEmpty }
        #expect(await collected.events == [.available(false)])
    }

    // MARK: Guest to host

    @Test func aGuestGrabBecomesAnOffer() async throws {
        let main = RecordingTransport(input: try script([
            serverAgentData(guestCaps(), hasSelection: false),
            serverAgentData(.clipboardGrab(.clipboard, [.utf8Text])),
        ]))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { await collected.events.contains(.guestOffers([.utf8Text])) }
        #expect(await collected.events == [.available(true), .guestOffers([.utf8Text])])
    }

    @Test func requestingTheGuestClipboardSendsARequestAndConvertsTheAnswerToLF() async throws {
        let main = RecordingTransport(input: try script([
            serverAgentData(guestCaps(), hasSelection: false),
            serverAgentData(.clipboard(.clipboard, .utf8Text, Array("one\r\ntwo\r\n".utf8) + [0])),
        ]))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { await collected.events.contains(.available(true)) }
        await session.requestClipboard(.utf8Text)

        try await waitFor { try await self.clientAgentMessages(main).count >= 2 }
        #expect(try await clientAgentMessages(main).last == .clipboardRequest(.clipboard, .utf8Text))

        try await waitFor { await collected.events.count >= 2 }
        // The trailing NUL is gone and CRLF has become LF: what the Mac pasteboard wants.
        #expect(await collected.events.last == .guestData(.utf8Text, Array("one\ntwo\n".utf8)))
    }

    @Test func aGuestWithLFEndingsGetsItsTextThrough() async throws {
        let main = RecordingTransport(input: try script([
            serverAgentData(guestCaps(crlf: false), hasSelection: false),
            serverAgentData(.clipboard(.clipboard, .utf8Text, Array("a\r\nb".utf8))),
        ]))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { await collected.events.count >= 2 }
        // No CRLF capability means no conversion — the bytes are the guest's own.
        #expect(await collected.events.last == .guestData(.utf8Text, Array("a\r\nb".utf8)))
    }

    // MARK: Host to guest

    @Test func offeringAndAnsweringUsesTheGuestsLineEndings() async throws {
        let main = RecordingTransport(input: try script([
            serverAgentData(guestCaps(), hasSelection: false),
            serverAgentData(.clipboardRequest(.clipboard, .utf8Text)),
        ]))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { await collected.events.contains(.guestRequests(.utf8Text)) }

        await session.offerClipboard([.utf8Text])
        await session.sendClipboard(.utf8Text, Array("x\ny\n".utf8))

        try await waitFor { try await self.clientAgentMessages(main).count >= 3 }
        let sent = try await clientAgentMessages(main)
        #expect(sent[1] == .clipboardGrab(.clipboard, [.utf8Text]))
        // LF became CRLF on the way out, because this guest said it wants CRLF.
        #expect(sent[2] == .clipboard(.clipboard, .utf8Text, Array("x\r\ny\r\n".utf8)))
    }

    /// Clipboard messages before the guest has announced anything would be sent under the wrong
    /// selection convention and against a peer that may not do clipboard at all.
    @Test func nothingIsSentBeforeTheGuestAnnouncesCapabilities() async throws {
        let main = RecordingTransport(input: try script())
        let (session, _) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { try await !self.clientAgentMessages(main).isEmpty }
        await session.offerClipboard([.utf8Text])
        await session.sendClipboard(.utf8Text, Array("nope".utf8))
        try await Task.sleep(for: .milliseconds(40))

        // Only our own capability announcement went out.
        #expect(try await clientAgentMessages(main).count == 1)
    }

    // MARK: Flow control

    /// Every MAIN_AGENT_DATA costs a token. With one to spend, a message that needs three chunks
    /// must stall after the first and finish only once the server grants more.
    @Test func agentDataWaitsForTokens() async throws {
        var mmt = SpiceWriter(); mmt.u32(0)
        let main = RecordingTransport(input: try script(tokens: 1, [
            serverAgentData(guestCaps(), hasSelection: false),
        ]))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { await collected.events.contains(.available(true)) }
        // The one token went on our capability announcement.
        let spent = try await clientFrames(main).filter { $0.type == MainClientMsg.agentData.rawValue }.count
        #expect(spent == 1)

        await session.sendClipboard(.utf8Text, [UInt8](repeating: 0x41, count: 5000))
        try await Task.sleep(for: .milliseconds(40))
        #expect(try await clientFrames(main).filter { $0.type == MainClientMsg.agentData.rawValue }.count == 1)
    }

    @Test func aHostileAgentLengthDoesNotTakeTheSessionDown() async throws {
        var bad = SpiceWriter()
        bad.u32(VDAgent.version); bad.u32(AgentMsgType.clipboard.rawValue); bad.u64(0); bad.u32(.max)
        let main = RecordingTransport(input: try script([
            serverAgentData(guestCaps(), hasSelection: false),
            frame(MainServerMsg.agentData.rawValue, bad.bytes),
        ]))
        let (session, collected) = try await open(main)
        defer { Task { await session.disconnect() } }

        try await waitFor { await collected.events.contains(.available(true)) }
        try await Task.sleep(for: .milliseconds(40))
        // The agent is dropped, not the session: no crash, and no bogus clipboard event.
        #expect(await collected.events == [.available(true)])
    }
}
