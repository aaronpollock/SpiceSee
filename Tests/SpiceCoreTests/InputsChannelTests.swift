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

private func openInputs(_ body: [UInt8] = frame(InputsServerMsg.`init`.rawValue, [2, 0])) async throws -> (InputsChannel, InMemoryTransport) {
    let t = InMemoryTransport(input: try fakeLink(body: body))
    return (try await InputsChannel.open(transport: t, connectionID: 1, password: nil), t)
}

/// The INIT frame has to travel reader.run -> AsyncStream -> pump task -> handle before
/// guestLockKeys reflects it; poll instead of a fixed sleep so this isn't flaky under load.
private func waitForLockKeys(_ ch: InputsChannel) async throws {
    for _ in 0 ..< 400 {
        if await ch.guestLockKeys != [] { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func advertisesKeyScancodeAndReadsInit() async throws {
    let (ch, t) = try await openInputs()
    try await waitForLockKeys(ch)
    #expect(await ch.guestLockKeys == [.numLock])
    var r = SpiceReader(await t.written); try r.skip(16 + 4 + 2 + 4 + 4 + 4 + 4)   // header, conn id, type/id, ncommon, nchannel, offset, common word
    #expect(CapabilitySet(words: [try r.u32()]).contains(InputsCap.keyScancode))
}

@Test func keysTrackHeldSetAndReleaseAll() async throws {
    let (ch, t) = try await openInputs()
    let a = XTScancode(0x1E), ctrl = XTScancode(0x1D, extended: true)
    try await ch.keyDown(ctrl); try await ch.keyDown(a); try await ch.keyUp(a)
    #expect(await ch.heldKeys == [ctrl])
    try await ch.releaseAllKeys()
    #expect(await ch.heldKeys.isEmpty)
    let f = try await sentFrames(t).filter { $0.0 == InputsClientMsg.keyDown.rawValue || $0.0 == InputsClientMsg.keyUp.rawValue }
    #expect(f.map(\.1) == [ClientMessage.keyDown(ctrl), ClientMessage.keyDown(a), ClientMessage.keyUp(a), ClientMessage.keyUp(ctrl)])
}

@Test func buttonsStateAccumulates() async throws {
    let (ch, t) = try await openInputs()
    try await ch.buttonDown(.left); try await ch.buttonDown(.right); try await ch.mouseMotion(dx: 1, dy: 0); try await ch.buttonUp(.left)
    let f = try await sentFrames(t).filter { $0.0 >= 111 }
    #expect(f.map(\.1) == [ClientMessage.mousePress(.left, buttons: [.left]),
                           ClientMessage.mousePress(.right, buttons: [.left, .right]),
                           ClientMessage.mouseMotion(dx: 1, dy: 0, buttons: [.left, .right]),
                           ClientMessage.mouseRelease(.left, buttons: [.right])])
}

@Test func motionIsThrottledUntilAck() async throws {
    // No ACK in the input: the 9th and 10th motions must be held, coalesced, and not written.
    let (ch, t) = try await openInputs()
    for _ in 0 ..< 10 { try await ch.mouseMotion(dx: 1, dy: 1) }
    let before = try await sentFrames(t).filter { $0.0 == InputsClientMsg.mouseMotion.rawValue }
    #expect(before.count == 8)
    await ch.handleForTesting(.mouseMotionAck)
    let after = try await sentFrames(t).filter { $0.0 == InputsClientMsg.mouseMotion.rawValue }
    #expect(after.count == 9 && after.last?.1 == ClientMessage.mouseMotion(dx: 2, dy: 2, buttons: []))
}

@Test func keysUseScancodeMessageWhenServerAdvertisesIt() async throws {
    let t = InMemoryTransport(input: try fakeLink(channelCaps: 1 << InputsCap.keyScancode,
                                                  body: frame(InputsServerMsg.`init`.rawValue, [0, 0])))
    let ch = try await InputsChannel.open(transport: t, connectionID: 1, password: nil)
    let s = XTScancode(0x53, extended: true)
    try await ch.keyDown(s); try await ch.keyUp(s)
    let frames = try await sentFrames(t)
    #expect(frames.filter { $0.0 == InputsClientMsg.keyDown.rawValue || $0.0 == InputsClientMsg.keyUp.rawValue }.isEmpty)
    let scancodes = frames.filter { $0.0 == InputsClientMsg.keyScancode.rawValue }.map(\.1)
    #expect(scancodes == [[0xE0, 0x53], [0xE0, 0xD3]])
}

@Test func capsLockSyncPreservesGuestNumAndScroll() async throws {
    let (ch, t) = try await openInputs(frame(InputsServerMsg.`init`.rawValue, [3, 0]))   // guest: scroll + num
    try await waitForLockKeys(ch)
    try await ch.syncCapsLock(true)
    let f = try await sentFrames(t).filter { $0.0 == InputsClientMsg.keyModifiers.rawValue }
    #expect(f.last?.1 == ClientMessage.keyModifiers([.scrollLock, .numLock, .capsLock]))
}
