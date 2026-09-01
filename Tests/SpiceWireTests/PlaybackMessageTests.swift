import Testing
@testable import SpiceWire

/// Layouts follow spice.proto / spice-gtk channel-playback.c; ids 101…107.
@Suite struct PlaybackMessageTests {
    @Test func startParsesChannelsFormatFrequencyTime() throws {
        var w = SpiceWriter(); w.u32(2); w.u16(AudioFormat.s16); w.u32(48000); w.u32(1234)
        let m = try PlaybackMessage(type: PlaybackServerMsg.start.rawValue, payload: w.bytes)
        #expect(m == .start(PlaybackStart(channels: 2, format: AudioFormat.s16, frequency: 48000, time: 1234)))
    }

    @Test func modeCarriesTimeAndRawMode() throws {
        var w = SpiceWriter(); w.u32(99); w.u16(AudioDataMode.opus.rawValue)
        #expect(try PlaybackMessage(type: PlaybackServerMsg.mode.rawValue, payload: w.bytes) == .mode(time: 99, mode: 3))
    }

    @Test func dataIsTimeThenTheRestOfTheMessage() throws {
        var w = SpiceWriter(); w.u32(7); w.bytes([1, 2, 3])
        #expect(try PlaybackMessage(type: PlaybackServerMsg.data.rawValue, payload: w.bytes) == .data(time: 7, payload: [1, 2, 3]))
    }

    @Test func volumeIsCountedU16s() throws {
        var w = SpiceWriter(); w.u8(2); w.u16(65535); w.u16(0)
        #expect(try PlaybackMessage(type: PlaybackServerMsg.volume.rawValue, payload: w.bytes) == .volume([65535, 0]))
    }

    @Test func muteStopLatency() throws {
        #expect(try PlaybackMessage(type: PlaybackServerMsg.mute.rawValue, payload: [1]) == .mute(true))
        #expect(try PlaybackMessage(type: PlaybackServerMsg.stop.rawValue, payload: []) == .stop)
        var w = SpiceWriter(); w.u32(40)
        #expect(try PlaybackMessage(type: PlaybackServerMsg.latency.rawValue, payload: w.bytes) == .latency(ms: 40))
    }

    @Test func truncatedPayloadsThrowRatherThanTrap() {
        #expect(throws: (any Error).self) { try PlaybackMessage(type: PlaybackServerMsg.start.rawValue, payload: [0, 0, 0]) }
        #expect(throws: (any Error).self) { try PlaybackMessage(type: PlaybackServerMsg.data.rawValue, payload: [0, 0]) }
        // VOLUME announcing more channels than bytes follow.
        #expect(throws: (any Error).self) { try PlaybackMessage(type: PlaybackServerMsg.volume.rawValue, payload: [3, 0, 0]) }
    }

    @Test func unknownTypeIsOther() throws {
        #expect(try PlaybackMessage(type: 150, payload: [9]) == .other(type: 150))
    }
}
