import Testing
@testable import SpiceMedia

/// Apple's Opus decoder checked against libopus's encoder — never against itself.
@Suite struct OpusDecoderTests {
    @Test func opusIsAvailableOnThisMac() {
        #expect(OpusDecoder.isAvailable())
    }

    @Test func decodesTheLibopusToneFrameAccurate() throws {
        let decoder = try OpusDecoder(sampleRate: 48000, channels: 2)
        var frames = 0
        var sumSq = 0.0
        for packet in try opusFixturePackets() {
            let pcm = try decoder.decode(packet)
            frames += pcm.count / 2
            for s in pcm { sumSq += Double(s * s) }
        }
        // 100 × 480 encoded; the decoder applies Opus's 120-sample pre-skip itself.
        #expect(frames == 48000 - 120)
        let rms = (sumSq / Double(frames * 2)).squareRoot()
        #expect(abs(rms - 0.354) < 0.004)      // 0.5-amplitude sine → 0.5/√2, within 1 %
    }

    @Test func garbageIsAnErrorNotATrap() throws {
        let decoder = try OpusDecoder(sampleRate: 48000, channels: 2)
        // Either an error or an empty/even-length result is acceptable; a crash is not.
        let r = try? decoder.decode([0xFF, 0x00, 0x13, 0x37])
        #expect(r == nil || r!.count % 2 == 0)
    }

    @Test func emptyPacketDecodesToNothing() throws {
        let decoder = try OpusDecoder(sampleRate: 48000, channels: 2)
        #expect(try decoder.decode([]).isEmpty)
    }
}
