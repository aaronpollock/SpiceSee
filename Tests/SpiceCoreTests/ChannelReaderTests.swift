import Testing
import SpiceWire
@testable import SpiceCore

private func msg(_ type: UInt16, _ payload: [UInt8]) -> [UInt8] {
    ClientMessage.frame(type: type, payload: payload, mini: true, serial: 0)
}

@Test func yieldsMessagesAndAnswersSetAckAndPing() async throws {
    var setAck = SpiceWriter(); setAck.u32(3); setAck.u32(2)   // generation 3, window 2
    var ping = SpiceWriter(); ping.u32(11); ping.u64(99)
    let input = msg(CommonServerMsg.setAck.rawValue, setAck.bytes)
              + msg(103, [1]) + msg(104, [2]) + msg(105, [3])
              + msg(CommonServerMsg.ping.rawValue, ping.bytes)
    let t = InMemoryTransport(input: input)
    let reader = ChannelReader(source: t, sink: t, miniHeader: true, channel: .init(type: .main, id: 0))
    let task = Task { await reader.run() }
    var got: [RawMessage] = []
    for await m in reader.messages { got.append(m) }
    await task.value

    #expect(got == [RawMessage(type: 103, payload: [1]), RawMessage(type: 104, payload: [2]), RawMessage(type: 105, payload: [3])])
    let written = await t.written
    // ACK_SYNC(gen 3), then an ACK every 2 messages received — after 104, and again on the ping,
    // which counts toward the window like any other message the server sent.
    var expected = msg(CommonClientMsg.ackSync.rawValue, [3, 0, 0, 0])
    expected += msg(CommonClientMsg.ack.rawValue, [])
    expected += msg(CommonClientMsg.ack.rawValue, [])
    expected += msg(CommonClientMsg.pong.rawValue, ping.bytes)
    #expect(written == expected)
}

@Test func fullHeaderMode() async throws {
    let input = ClientMessage.frame(type: 103, payload: [7], mini: false, serial: 1)
    let t = InMemoryTransport(input: input)
    let reader = ChannelReader(source: t, sink: t, miniHeader: false, channel: .init(type: .main, id: 0))
    Task { await reader.run() }
    var got: [RawMessage] = []
    for await m in reader.messages { got.append(m) }
    #expect(got == [RawMessage(type: 103, payload: [7])])
}

@Test func oversizedHeaderEndsStream() async throws {
    var w = SpiceWriter(); w.u16(103); w.u32(0xFFFF_FFFF)
    let t = InMemoryTransport(input: w.bytes)
    let reader = ChannelReader(source: t, sink: t, miniHeader: true, channel: .init(type: .main, id: 0))
    Task { await reader.run() }
    var count = 0
    for await _ in reader.messages { count += 1 }
    #expect(count == 0)
}

/// The server counts *every* message it sends against the ack window, including the ones a client
/// consumes internally. Counting only the messages we forward drifts by one per ping until the
/// server's window is exhausted and it stops sending — the display channel then freezes and
/// spice-server eventually drops it with `flush_commands: flush timeout`.
@Test func pingsCountTowardTheAckWindow() async throws {
    var setAck = SpiceWriter(); setAck.u32(1); setAck.u32(2)   // generation 1, window 2
    var ping = SpiceWriter(); ping.u32(7); ping.u64(0)
    let input = msg(CommonServerMsg.setAck.rawValue, setAck.bytes)
              + msg(CommonServerMsg.ping.rawValue, ping.bytes)
              + msg(CommonServerMsg.ping.rawValue, ping.bytes)
    let t = InMemoryTransport(input: input)
    let reader = ChannelReader(source: t, sink: t, miniHeader: true, channel: .init(type: .display, id: 0))
    let task = Task { await reader.run() }
    for await _ in reader.messages {}
    await task.value

    let written = await t.written
    #expect(occurrences(of: msg(CommonClientMsg.ack.rawValue, []), in: written) == 1,
            "two pings fill a window of 2 and must be acknowledged")
}

private func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> Int {
    guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
    var i = 0, hits = 0
    while i + needle.count <= haystack.count {
        if Array(haystack[i ..< i + needle.count]) == needle { hits += 1; i += needle.count } else { i += 1 }
    }
    return hits
}
