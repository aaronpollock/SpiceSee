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
    // Two `.stopped`: the server's PLAYBACK_STOP, then the one the pump yields when the channel
    // itself closes — audio is non-fatal, so that is the session's only word about it.
    #expect(audio == [.started(sampleRate: 48000, channels: 2, opus: false),
                      .pcm(frames: [0, 0.5], mmTime: 60_000),
                      .stopped, .stopped])
    #expect(disconnectedLast)
}

/// A main transport that serves its script and then holds the connection open, so the session is
/// still live when the playback channel hits EOF. `InMemoryTransport` would end main first and the
/// test would prove nothing. (`ClipboardSessionTests.RecordingTransport` minus the recording — SPM
/// test targets cannot share sources across files' private types.)
private actor HoldingTransport: Transport {
    private let input: [UInt8]
    private var cursor = 0
    private var waiters: [CheckedContinuation<[UInt8], Error>] = []
    private var closed = false
    init(input: [UInt8]) { self.input = input }

    func read(exactly n: Int) async throws -> [UInt8] {
        guard !closed else { throw SpiceError(.closed, underlying: "closed") }
        if input.count - cursor >= n { defer { cursor += n }; return Array(input[cursor ..< cursor + n]) }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func write(_ bytes: [UInt8]) {}
    func close() {
        closed = true
        waiters.forEach { $0.resume(throwing: SpiceError(.closed, underlying: "closed")) }
        waiters.removeAll()
    }
}

private actor Marks {
    private(set) var marks: [String] = []
    func add(_ m: String) { marks.append(m) }
}

/// A guest whose sound device goes away must keep its desktop: unlike display or cursor, a closed
/// playback channel ends audio only.
@Test func aClosedPlaybackChannelDoesNotEndTheSession() async throws {
    let main = HoldingTransport(input: try mainBytesWithPlayback())
    let session = try await SpiceSession.connect(password: nil) { desc in
        if desc.type == .main { return main }
        return InMemoryTransport(input: try fakeLink(body: []))          // playback: EOF at once
    }
    let marks = Marks()
    let collector = Task { [events = session.events] in
        for await e in events {
            switch e {
            case .audio(.stopped): await marks.add("stopped")
            case .disconnected: await marks.add("disconnected"); return
            default: continue
            }
        }
    }
    for _ in 0 ..< 200 {
        if await !marks.marks.isEmpty { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await marks.marks == ["stopped"])
    try await Task.sleep(for: .milliseconds(300))
    #expect(await marks.marks == ["stopped"])          // the session outlives the playback channel
    await session.disconnect()
    await collector.value
    #expect(await marks.marks == ["stopped", "disconnected"])
}
