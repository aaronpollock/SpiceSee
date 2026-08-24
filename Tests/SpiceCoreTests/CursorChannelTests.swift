import Foundation
import Testing
import SpiceWire
@testable import SpiceCore

@Test func cursorChannelStreamsParsedMessages() async throws {
    var set = SpiceWriter(); set.u16(1); set.u16(2); set.u8(1); set.u16(CursorFlags.none)
    var mv = SpiceWriter(); mv.u16(7); mv.u16(8)
    let body = frame(CursorServerMsg.set.rawValue, set.bytes) + frame(CursorServerMsg.move.rawValue, mv.bytes)
             + frame(CursorServerMsg.hide.rawValue, []) + frame(CursorServerMsg.move.rawValue, [1])   // last one malformed: dropped, not fatal
    let t = InMemoryTransport(input: try fakeLink(body: body))
    let ch = try await CursorChannel.open(transport: t, connectionID: 1, id: 0, password: nil)
    var got: [CursorMessage] = []
    for await m in ch.messages { got.append(m) }
    #expect(got == [.set(position: SpicePoint16(x: 1, y: 2), visible: true, cursor: SpiceCursor(flags: 1, header: nil, data: [])),
                    .move(SpicePoint16(x: 7, y: 8)), .hide])
}
