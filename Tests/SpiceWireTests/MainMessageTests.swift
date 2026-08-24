import Testing
@testable import SpiceWire

@Test func miniAndFullHeadersRoundTrip() throws {
    let h = DataHeader(serial: 7, type: 103, size: 32, subList: 0)
    var mini = SpiceReader(h.encode(mini: true))
    #expect(try DataHeader(mini: &mini) == DataHeader(serial: 0, type: 103, size: 32, subList: 0))
    var full = SpiceReader(h.encode(mini: false))
    #expect(try DataHeader(full: &full) == h)
    #expect(h.encode(mini: true).count == 6)
    #expect(h.encode(mini: false).count == 18)
}

@Test func mainInitParses() throws {
    var w = SpiceWriter()
    [1, 2, 3, 2, 1, 10, 5000, 0].forEach { w.u32(UInt32($0)) }
    let m = try MainMessage(type: MainServerMsg.`init`.rawValue, payload: w.bytes)
    guard case let .`init`(i) = m else { Issue.record("wrong case"); return }
    #expect(i.sessionID == 1)
    #expect(i.displayChannelsHint == 2)
    #expect(i.currentMouseMode == 2)
    #expect(i.agentTokens == 10)
    #expect(i.multiMediaTime == 5000)
}

@Test func channelsListSkipsUnknownTypes() throws {
    var w = SpiceWriter()
    w.u32(3); w.u8(2); w.u8(0); w.u8(99); w.u8(0); w.u8(4); w.u8(0)
    let m = try MainMessage(type: MainServerMsg.channelsList.rawValue, payload: w.bytes)
    guard case let .channelsList(l) = m else { Issue.record("wrong case"); return }
    #expect(l.channels == [ChannelDescriptor(type: .display, id: 0), ChannelDescriptor(type: .cursor, id: 0)])
}

@Test func truncatedMainInitThrows() {
    #expect(throws: WireError.self) { _ = try MainMessage(type: MainServerMsg.`init`.rawValue, payload: [1, 2, 3]) }
}

@Test func pongEchoesPing() throws {
    let ping = Ping(id: 9, timestamp: 1234)
    var r = SpiceReader(ClientMessage.pong(ping))
    #expect(try r.u32() == 9)
    #expect(try r.u64() == 1234)
}

@Test func frameBuildsMiniHeader() throws {
    let f = ClientMessage.frame(type: 2, payload: [0xAA], mini: true, serial: 1)
    #expect(f == [2, 0, 1, 0, 0, 0, 0xAA])
}
