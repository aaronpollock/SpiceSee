import Testing
import SpiceWire
@testable import SpiceMedia

private func start(_ rate: UInt32 = 48000, channels: UInt32 = 2) -> PlaybackMessage {
    .start(PlaybackStart(channels: channels, format: AudioFormat.s16, frequency: rate, time: 0))
}

private func s16(_ samples: [Int16]) -> [UInt8] {
    samples.flatMap { let u = UInt16(bitPattern: $0); return [UInt8(u & 0xFF), UInt8(u >> 8)] }
}

private func drain(_ p: AudioPlayer) async -> [AudioEvent] {
    await p.finish()
    var out: [AudioEvent] = []
    for await e in p.events { out.append(e) }
    return out
}

@Test func startAnnouncesFormatAndCodec() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.mode(time: 0, mode: AudioDataMode.opus.rawValue))
    await p.handle(start())
    #expect(await drain(p) == [.started(sampleRate: 48000, channels: 2, opus: true)])
}

@Test func rawS16ConvertsExactly() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.mode(time: 0, mode: AudioDataMode.raw.rawValue))
    await p.handle(start())
    await p.handle(.data(time: 0, payload: s16([0, 32767, -32768, 16384])))
    let events = await drain(p)
    guard case let .pcm(frames, mmTime)? = events.last else { Issue.record("no pcm: \(events)"); return }
    #expect(mmTime == 0)
    #expect(frames == [0, Float(32767) / 32768, -1, 0.5])
}

@Test func latePacketsDropBeforeDecode() async throws {
    let p = AudioPlayer(opusAvailable: true)
    await p.setMMTime(10_000)
    await p.handle(.mode(time: 0, mode: AudioDataMode.opus.rawValue))
    await p.handle(start())
    await p.handle(.data(time: 5_000, payload: [0xFF, 0xFF, 0xFF]))       // 5 s late and garbage: never decoded
    #expect(await p.decodeAttempts == 0)
    #expect(await p.droppedLate == 1)
    await p.handle(.data(time: 10_000, payload: try opusFixturePackets()[0]))
    #expect(await p.decodeAttempts == 1)
}

@Test func theLibopusToneDecodesThroughThePlayer() async throws {
    let p = AudioPlayer(opusAvailable: true)          // no setMMTime: nothing can be late
    await p.handle(.mode(time: 0, mode: AudioDataMode.opus.rawValue))
    await p.handle(start())
    for (i, packet) in try opusFixturePackets().enumerated() { await p.handle(.data(time: UInt32(i * 10), payload: packet)) }
    let frames = await drain(p).reduce(0) { n, e in if case let .pcm(f, _) = e { return n + f.count / 2 }; return n }
    #expect(frames == 48000 - 120)
}

@Test func volumeAndMuteMapToTheSeam() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.volume([65535, 0]))
    await p.handle(.mute(true))
    #expect(await drain(p) == [.volume([1, 0]), .mute(true)])
}

@Test func stopEmitsStopped() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.mode(time: 0, mode: AudioDataMode.raw.rawValue))
    await p.handle(start())
    await p.handle(.stop)
    #expect(await drain(p) == [.started(sampleRate: 48000, channels: 2, opus: false), .stopped])
}

@Test func opusUnavailableDropsOpusButRawStillPlays() async throws {
    let p = AudioPlayer(opusAvailable: false)
    await p.handle(.mode(time: 0, mode: AudioDataMode.opus.rawValue))
    await p.handle(start())
    await p.handle(.data(time: 0, payload: try opusFixturePackets()[0]))
    await p.handle(.stop)
    await p.handle(.mode(time: 0, mode: AudioDataMode.raw.rawValue))
    await p.handle(start())
    await p.handle(.data(time: 0, payload: s16([100, -100])))
    let pcm = await drain(p).filter { if case .pcm = $0 { return true }; return false }
    #expect(pcm.count == 1)                            // only the raw packet made it
}

@Test func dataBeforeStartIsDropped() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.mode(time: 0, mode: AudioDataMode.raw.rawValue))
    await p.handle(.data(time: 0, payload: s16([1, 2])))
    #expect(await drain(p).isEmpty)
}
