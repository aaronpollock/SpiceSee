import Testing
import SpiceWire
@testable import SpiceCore

/// The monitors-config gate: nothing goes out until the guest has said it does monitors config,
/// and what goes out once it has is the message Task 1 pinned.
@Suite struct AgentSessionMonitorsTests {
    private actor Sink {
        private(set) var chunks: [[UInt8]] = []
        func add(_ c: [UInt8]) { chunks.append(c) }
    }

    /// One MAIN_AGENT_DATA payload carrying `m`, as the server would relay it from the guest.
    private func fromGuest(_ m: AgentMessage) -> [UInt8] {
        AgentMessage.chunks(m.frame(hasSelection: true)).flatMap { $0 }
    }

    private func started(_ sink: Sink, guestCaps bits: [UInt32]) async -> AgentSession {
        let agent = AgentSession { chunk in await sink.add(chunk) }
        await agent.setTokens(10)
        await agent.agentConnected()
        await agent.receive(fromGuest(.announceCapabilities(request: false, caps: CapabilitySet(bits: bits))))
        return agent
    }

    @Test func guestWithoutTheCapIsNotSentAConfig() async {
        let sink = Sink()
        let agent = await started(sink, guestCaps: [AgentCap.clipboardByDemand])
        #expect(await agent.guestSupportsMonitorsConfig == false)
    }

    @Test func guestWithTheCapIs() async {
        let sink = Sink()
        let agent = await started(sink, guestCaps: [AgentCap.clipboardByDemand, AgentCap.monitorsConfig])
        #expect(await agent.guestSupportsMonitorsConfig)
        await agent.send(.monitorsConfig(flags: AgentMonitorsFlags.usePosition,
                                         monitors: [AgentMonitorConfig(width: 1920, height: 1080)]))
        // Chunk 0 is our announceCapabilities; the config must have followed it.
        let sent = await sink.chunks
        #expect(sent.count == 2)
        var r = SpiceReader(sent[1])
        _ = try? r.u32()                      // protocol
        #expect((try? r.u32()) == AgentMsgType.monitorsConfig.rawValue)
    }

    @Test func clientAnnouncesSparseMonitorsConfig() {
        #expect(AgentSession.clientCaps.contains(AgentCap.sparseMonitorsConfig))
    }
}
