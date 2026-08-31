import Testing
import SpiceWire
@testable import SpiceCore

/// Bytes the channel wrote after the link exchange, split into (type, payload) mini-header frames.
private func sentFrames(_ t: InMemoryTransport) async throws -> [(UInt16, [UInt8])] {
    let all = await t.written
    var r = SpiceReader(all)
    try r.skip(12); let n = Int(try r.u32()); try r.skip(n)      // link header size field, then the mess
    try r.skip(Link.ticketBytes)                                  // ticket only: fakeLink's reply doesn't advertise AUTH_SELECTION
    var out: [(UInt16, [UInt8])] = []
    while r.remaining >= DataHeader.miniSize {
        let h = try DataHeader(mini: &r); out.append((h.type, try r.bytes(Int(h.size))))
    }
    return out
}

@Test func sendsStreamReportFrame() async throws {
    let t = InMemoryTransport(input: try fakeLink(body: []))
    let ch = try await DisplayChannel.open(transport: t, connectionID: 1, id: 0, password: nil)
    let report = StreamReport(streamID: 7, uniqueID: 1, startFrameMMTime: 0, endFrameMMTime: 100,
                               numFrames: 10, numDrops: 1, lastFrameDelay: 5, audioDelay: .max)
    try await ch.send(streamReport: report)
    let f = try await sentFrames(t).filter { $0.0 == DisplayClientMsg.streamReport.rawValue }
    #expect(f.count == 1)
    #expect(f.first?.1.count == 32)
}
