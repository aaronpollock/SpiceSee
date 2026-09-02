import Foundation
import Testing
import SpiceWire
import SpiceMedia
@testable import SpiceCore
@testable import SpiceKit

/// MAIN_INIT + CHANNELS_LIST advertising exactly one playback channel, id 0.
private func mainBytesWithPlayback() throws -> [UInt8] {
    var mi = SpiceWriter(); [1, 1, SpiceMouseMode.server, SpiceMouseMode.server, 0, 10, 0, 0].forEach { mi.u32($0) }
    var cl = SpiceWriter(); cl.u32(1); cl.u8(ChannelType.playback.rawValue); cl.u8(0)
    return try fakeLink(body: frame(MainServerMsg.`init`.rawValue, mi.bytes) + frame(MainServerMsg.channelsList.rawValue, cl.bytes))
}

@Test func playbackMessagesSurfaceAsAudioEventsAndDisconnectedComesLast() async throws {
    var mode = SpiceWriter(); mode.u32(0); mode.u16(AudioDataMode.raw.rawValue)
    var start = SpiceWriter(); start.u32(2); start.u16(AudioFormat.s16); start.u32(48000); start.u32(0)
    // mmTime is far ahead of the mm clock seeded from MAIN_INIT (0): AudioPlayer drops a packet
    // more than 80ms "late" against wall-clock elapsed time, and a full `swift test` run under
    // heavy parallel load can easily take longer than that to reach this message. A large mmTime
    // keeps this test about routing, not about racing the scheduler.
    var data = SpiceWriter(); data.u32(60_000); data.bytes([0, 0, 0, 0x40])   // L=0, R=0.5
    let body = frame(PlaybackServerMsg.mode.rawValue, mode.bytes)
             + frame(PlaybackServerMsg.start.rawValue, start.bytes)
             + frame(PlaybackServerMsg.data.rawValue, data.bytes)
             + frame(PlaybackServerMsg.stop.rawValue, [])
    let main = InMemoryTransport(input: try mainBytesWithPlayback())
    let playback = InMemoryTransport(input: try fakeLink(body: body))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return main
        case .playback: return playback
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    var audio: [AudioEvent] = []
    var disconnectedLast = false
    for await e in session.events {
        switch e {
        case let .audio(a): audio.append(a); disconnectedLast = false
        case .disconnected: disconnectedLast = true
        default: continue
        }
        if case .disconnected = e { break }
    }
    #expect(audio == [.started(sampleRate: 48000, channels: 2, opus: false),
                      .pcm(frames: [0, 0.5], mmTime: 60_000),
                      .stopped])
    #expect(disconnectedLast)
}
