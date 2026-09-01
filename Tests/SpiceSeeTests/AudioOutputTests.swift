import AVFoundation
import Testing
@testable import SpiceSee

@MainActor
@Suite struct AudioOutputTests {
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    private func offlineEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4096)
        return engine
    }

    /// `ms` of full-scale stereo silence-or-tone as the seam delivers it: interleaved Float32.
    private func chunk(ms: Int, amplitude: Float = 0.5) -> AudioEvent {
        let n = 48 * ms
        var frames = [Float](repeating: 0, count: n * 2)
        for i in 0 ..< n { let v = amplitude * sinf(Float(i) * 2 * .pi * 440 / 48000); frames[i * 2] = v; frames[i * 2 + 1] = v }
        return .pcm(frames: frames, mmTime: 0)
    }

    private func rms(_ engine: AVAudioEngine, frames: AVAudioFrameCount = 2048) throws -> Float {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        let status = try engine.renderOffline(frames, to: buffer)
        #expect(status == .success)
        var sum: Float = 0
        for c in 0 ..< Int(buffer.format.channelCount) {
            let p = buffer.floatChannelData![c]
            for i in 0 ..< Int(buffer.frameLength) { sum += p[i] * p[i] }
        }
        return (sum / Float(Int(buffer.frameLength) * Int(buffer.format.channelCount))).squareRoot()
    }

    @Test func prebufferHoldsPlaybackUntilFiftyMilliseconds() throws {
        let output = AudioOutput(engine: try offlineEngine())
        output.handle(.started(sampleRate: 48000, channels: 2, opus: true))
        output.handle(chunk(ms: 20))
        #expect(!output.isPlaying)
        output.handle(chunk(ms: 20))
        #expect(!output.isPlaying)
        output.handle(chunk(ms: 20))         // 60 ms queued ≥ 50 ms target
        #expect(output.isPlaying)
    }

    @Test func toolbarMuteSilencesTheMixerButNotThePlayer() throws {
        let engine = try offlineEngine()
        let output = AudioOutput(engine: engine)
        output.handle(.started(sampleRate: 48000, channels: 2, opus: false))
        for _ in 0 ..< 5 { output.handle(chunk(ms: 20)) }
        #expect(try rms(engine) > 0.1)
        output.muted = true
        // AVAudioMixerNode's `outputVolume` is smoothed by the underlying AUMultiChannelMixer over
        // up to ~4096 samples — confirmed empirically, and not bypassable via the public API (a
        // direct, immediate-event AUParameter set ramps identically). Render past that window
        // before asserting exact silence; the intervening render is real audio, not silence.
        _ = try rms(engine, frames: 4096)
        #expect(try rms(engine) == 0)
        #expect(output.playerVolume == 1)     // the guest's own level is untouched
    }

    @Test func guestMuteAndVolumeDriveThePlayerNotTheMixer() throws {
        let engine = try offlineEngine()
        let output = AudioOutput(engine: engine)
        output.handle(.started(sampleRate: 48000, channels: 2, opus: false))
        output.handle(.volume([0.5, 0.5]))
        #expect(output.playerVolume == 0.5)
        output.handle(.mute(true))
        #expect(output.playerVolume == 0)
        #expect(engine.mainMixerNode.outputVolume == 1)
        output.handle(.mute(false))
        #expect(output.playerVolume == 0.5)
    }

    @Test func stoppedResetsThePrebuffer() throws {
        let output = AudioOutput(engine: try offlineEngine())
        output.handle(.started(sampleRate: 48000, channels: 2, opus: false))
        for _ in 0 ..< 3 { output.handle(chunk(ms: 20)) }
        #expect(output.isPlaying)
        output.handle(.stopped)
        #expect(!output.isPlaying)
        output.handle(chunk(ms: 20))
        #expect(!output.isPlaying)            // a fresh prebuffer, not a resumed one
    }
}
