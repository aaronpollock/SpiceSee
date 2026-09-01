import Foundation
import Testing
import SpiceWire
@testable import SpiceCore

@Test func playbackChannelStreamsParsedMessagesAndDropsMalformedOnes() async throws {
    var mode = SpiceWriter(); mode.u32(0); mode.u16(AudioDataMode.raw.rawValue)
    var start = SpiceWriter(); start.u32(2); start.u16(AudioFormat.s16); start.u32(48000); start.u32(5)
    var data = SpiceWriter(); data.u32(5); data.bytes([0, 0, 0xFF, 0x7F])
    let body = frame(PlaybackServerMsg.mode.rawValue, mode.bytes)
             + frame(PlaybackServerMsg.start.rawValue, start.bytes)
             + frame(PlaybackServerMsg.data.rawValue, data.bytes)
             + frame(PlaybackServerMsg.start.rawValue, [1, 2])          // truncated: dropped, not fatal
             + frame(PlaybackServerMsg.stop.rawValue, [])
    let t = InMemoryTransport(input: try fakeLink(body: body))
    let ch = try await PlaybackChannel.open(transport: t, connectionID: 1, id: 0, password: nil,
                                            caps: CapabilitySet(bits: [PlaybackCap.volume]))
    var got: [PlaybackMessage] = []
    for await m in ch.messages { got.append(m) }
    #expect(got == [.mode(time: 0, mode: 1),
                    .start(PlaybackStart(channels: 2, format: 1, frequency: 48000, time: 5)),
                    .data(time: 5, payload: [0, 0, 0xFF, 0x7F]),
                    .stop])
}
