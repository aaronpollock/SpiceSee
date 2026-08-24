import Foundation
import Testing
import SpiceWire
import SpiceCore
@testable import SpiceKit

/// A main channel whose MAIN_INIT advertises `supported` mouse modes and is `current`ly in one of them.
private func mainBytes(supported: UInt32, current: UInt32, trailing: [UInt8] = []) throws -> [UInt8] {
    var mi = SpiceWriter(); [1, 1, supported, current, 0, 10, 0, 0].forEach { mi.u32($0) }
    var cl = SpiceWriter(); cl.u32(3); cl.u8(2); cl.u8(0); cl.u8(3); cl.u8(0); cl.u8(4); cl.u8(0)   // display/0 inputs/0 cursor/0
    return try fakeLink(body: frame(MainServerMsg.`init`.rawValue, mi.bytes) + frame(MainServerMsg.channelsList.rawValue, cl.bytes) + trailing)
}

/// `fakeLink`'s reply never advertises PROTOCOL_AUTH_SELECTION, so the handshake writes the link
/// mess and the ticket and nothing else before the first client frame.
private func clientFrames(_ t: InMemoryTransport) async throws -> [(type: UInt16, payload: [UInt8])] {
    var r = SpiceReader(await t.written)
    try r.skip(12); let n = Int(try r.u32()); try r.skip(n); try r.skip(Link.ticketBytes)
    var out: [(UInt16, [UInt8])] = []
    while r.remaining >= DataHeader.miniSize { let h = try DataHeader(mini: &r); out.append((h.type, try r.bytes(Int(h.size)))) }
    return out
}

/// Polls until the transport has `count` client frames of `type`, so tests do not race the input pump.
private func waitForFrames(_ t: InMemoryTransport, type: UInt16, count: Int) async throws -> [[UInt8]] {
    for _ in 0 ..< 400 {
        let f = try await clientFrames(t).filter { $0.type == type }.map(\.payload)
        if f.count >= count { return f }
        try await Task.sleep(for: .milliseconds(5))
    }
    return try await clientFrames(t).filter { $0.type == type }.map(\.payload)
}

@Test func requestsClientModeWhenSupported() async throws {
    let main = InMemoryTransport(input: try mainBytes(supported: 3, current: SpiceMouseMode.server))
    let inputs = InMemoryTransport(input: try fakeLink(body: frame(InputsServerMsg.`init`.rawValue, [0, 0])))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return main
        case .inputs: return inputs
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    let req = try await waitForFrames(main, type: MainClientMsg.mouseModeRequest.rawValue, count: 1)
    #expect(req == [ClientMessage.mouseModeRequest(SpiceMouseMode.client)])
    var modes: [PointerMode] = []
    for await e in session.events { if case let .pointerMode(m) = e { modes.append(m) }; if case .disconnected = e { break } }
    #expect(modes.first == .server)
}

@Test func doesNotRequestClientModeWhenUnsupported() async throws {
    let main = InMemoryTransport(input: try mainBytes(supported: 1, current: SpiceMouseMode.server))
    let session = try await SpiceSession.connect(password: nil) { desc in
        desc.type == .main ? main : InMemoryTransport(input: try fakeLink(body: []))
    }
    for await e in session.events { if case .disconnected = e { break } }
    let req = try await clientFrames(main).filter { $0.type == MainClientMsg.mouseModeRequest.rawValue }
    #expect(req.isEmpty)
}

@Test func sendPreservesOrderAndEncoding() async throws {
    let inputs = InMemoryTransport(input: try fakeLink(body: frame(InputsServerMsg.`init`.rawValue, [2, 0])))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return InMemoryTransport(input: try mainBytes(supported: 1, current: 1))
        case .inputs: return inputs
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    let a = XTScancode(0x1E)
    session.send(.keyDown(a)); session.send(.keyUp(a))
    session.send(.buttonDown(.left)); session.send(.pointerMotion(dx: 3, dy: -4)); session.send(.buttonUp(.left))
    session.send(.wheel(clicks: -1))
    session.send(.hostCapsLock(true))
    session.send(.pointerPosition(x: 10, y: 20, displayID: 0))
    let all = try await waitForFrames(inputs, type: InputsClientMsg.mousePosition.rawValue, count: 1)
    #expect(all.last == ClientMessage.mousePosition(x: 10, y: 20, buttons: [], displayID: 0))

    // The caps-lock sync waits for INPUTS_INIT before it can merge num/scroll, so its frame is not
    // ordered with the rest; everything else must keep the order it was sent in.
    let expected: [(type: UInt16, payload: [UInt8])] = [
        (InputsClientMsg.keyDown.rawValue, ClientMessage.keyDown(a)),
        (InputsClientMsg.keyUp.rawValue, ClientMessage.keyUp(a)),
        (InputsClientMsg.mousePress.rawValue, ClientMessage.mousePress(.left, buttons: [.left])),
        (InputsClientMsg.mouseMotion.rawValue, ClientMessage.mouseMotion(dx: 3, dy: -4, buttons: [.left])),
        (InputsClientMsg.mouseRelease.rawValue, ClientMessage.mouseRelease(.left, buttons: [])),
        (InputsClientMsg.mousePress.rawValue, ClientMessage.mousePress(.down, buttons: [])),
        (InputsClientMsg.mouseRelease.rawValue, ClientMessage.mouseRelease(.down, buttons: [])),
        (InputsClientMsg.mousePosition.rawValue, ClientMessage.mousePosition(x: 10, y: 20, buttons: [], displayID: 0)),
    ]
    let frames = try await clientFrames(inputs).filter { $0.type > 100 && $0.type != InputsClientMsg.keyModifiers.rawValue }
    #expect(frames.map(\.type) == expected.map(\.type))
    for (got, want) in zip(frames, expected) { #expect(got.payload == want.payload) }

    // INIT said [2, 0] — num lock — so the deferred sync must add caps to it and send exactly once.
    let mods = try await waitForFrames(inputs, type: InputsClientMsg.keyModifiers.rawValue, count: 1)
    #expect(mods == [ClientMessage.keyModifiers([.numLock, .capsLock])])
    await session.disconnect()
}

@Test func cursorChangesCarryTheirDisplay() async throws {
    var set = SpiceWriter(); set.u16(4); set.u16(5); set.u8(1); set.u16(CursorFlags.none)
    let cursor = InMemoryTransport(input: try fakeLink(body: frame(CursorServerMsg.set.rawValue, set.bytes)))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return InMemoryTransport(input: try mainBytes(supported: 1, current: 1))
        case .cursor: return cursor
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    var moved: [(Int, Int, UInt8)] = []
    for await e in session.events {
        if case let .cursor(.moved(x, y), id) = e { moved.append((x, y, id)) }
        if case .disconnected = e { break }
    }
    #expect(moved.count == 1 && moved.first?.0 == 4 && moved.first?.1 == 5 && moved.first?.2 == 0)
}

@Test func reactsToMouseModeWithoutRelooping() async throws {
    var mm = SpiceWriter(); mm.u32(3); mm.u32(SpiceMouseMode.client)
    var tok = SpiceWriter(); tok.u32(10)
    let main = InMemoryTransport(input: try mainBytes(
        supported: 3, current: SpiceMouseMode.server,
        trailing: frame(MainServerMsg.mouseMode.rawValue, mm.bytes)
            + frame(MainServerMsg.agentConnectedTokens.rawValue, tok.bytes)))
    let session = try await SpiceSession.connect(password: nil) { desc in
        desc.type == .main ? main : InMemoryTransport(input: try fakeLink(body: []))
    }
    var modes: [PointerMode] = []
    var agent: [Bool] = []
    for await e in session.events {
        if case let .pointerMode(m) = e { modes.append(m) }
        if case let .agent(connected) = e { agent.append(connected) }
        if case .disconnected = e { break }
    }
    #expect(modes == [.server, .client])
    #expect(agent == [true])
    // Every write the session makes precedes `.disconnected`, so this needs no poll: once the guest
    // reports client mode the request must not be repeated.
    let req = try await clientFrames(main).filter { $0.type == MainClientMsg.mouseModeRequest.rawValue }
    #expect(req.count == 1)
    #expect(await session.pointerMode == .client)
}
