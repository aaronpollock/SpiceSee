import Foundation
import Testing
import SpiceWire
import SpiceCore
@testable import SpiceKit

private func mainLink(listing channels: [ChannelDescriptor]) throws -> [UInt8] {
    var mi = SpiceWriter(); [1, 1, 1, 1, 0, 10, 0, 0].forEach { mi.u32(UInt32($0)) }
    var cl = SpiceWriter(); cl.u32(UInt32(channels.count))
    channels.forEach { cl.u8($0.type.rawValue); cl.u8($0.id) }
    return try fakeLink(body: frame(MainServerMsg.`init`.rawValue, mi.bytes) + frame(MainServerMsg.channelsList.rawValue, cl.bytes))
}

/// The first `.disconnected`, or nil if the session is still going after `seconds`. A session that
/// never notices a dead channel would otherwise hang the test instead of failing it.
private func disconnection(of session: SpiceSession, within seconds: Double) async -> SpiceError?? {
    await withTaskGroup(of: SpiceError??.self) { group in
        group.addTask {
            for await e in session.events { if case let .disconnected(err) = e { return .some(err) } }
            return nil
        }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}

/// spice-server drops only the display client on `flush_commands: flush timeout`; main keeps
/// answering pings. That must end the session, not leave a frozen picture behind a live-looking one.
@Test func aDisplayChannelClosedByTheServerEndsTheSession() async throws {
    let display = ChannelDescriptor(type: .display, id: 0)
    let main = BlockingTransport(input: try mainLink(listing: [display]))
    let displayTransport = InMemoryTransport(input: try fakeLink(body: []))   // link, then the server's FIN

    let session = try await SpiceSession.connect(password: nil) { desc -> any Transport in
        desc.type == .main ? main : displayTransport
    }
    let outcome = await disconnection(of: session, within: 5)
    let reason = try #require(outcome, "the session never noticed the display channel closing")
    let error = try #require(reason, "a loss the user did not ask for must carry its reason")
    #expect(error.channel == display)
    if case .closed = error.kind {} else { Issue.record("expected .closed, got \(error.kind)") }
    #expect(await main.closed, "the surviving channel's socket must be released with the session")
    #expect(await displayTransport.closed, "the server's FIN must be answered, not left in CLOSE_WAIT")
}

@Test func userDisconnectReleasesEverySocket() async throws {
    let display = ChannelDescriptor(type: .display, id: 0)
    let main = BlockingTransport(input: try mainLink(listing: [display]))
    let displayTransport = BlockingTransport(input: try fakeLink(body: []))

    let session = try await SpiceSession.connect(password: nil) { desc in
        desc.type == .main ? main : displayTransport
    }
    await session.disconnect()
    let outcome = await disconnection(of: session, within: 5)
    let reason = try #require(outcome)
    #expect(reason == nil, "a disconnect the user asked for is not a loss")
    #expect(await main.closed)
    #expect(await displayTransport.closed)
}
