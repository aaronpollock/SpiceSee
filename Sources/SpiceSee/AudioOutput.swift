import AVFoundation
import os

/// The speaker end of the playback channel. Decoded frames arrive over the seam; this schedules
/// them on an `AVAudioPlayerNode` — never a realtime render callback, so there is no ring buffer
/// and no lock — and holds `play()` until ~50 ms are queued, which is the whole jitter buffer.
///
/// Two volume controls multiply: the guest's (`PLAYBACK_VOLUME`/`MUTE`, what its slider does)
/// lives on the player node; the toolbar's `muted` lives on the mixer. Neither overwrites the other.
@MainActor
final class AudioOutput {
    static let prebufferSeconds = 0.05

    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queuedBeforePlay: AVAudioFrameCount = 0
    private var playing = false
    private var guestVolume: Float = 1
    private var guestMuted = false
    private var loggedStartFailure = false
    private let log = Logger(subsystem: "com.spicesee", category: "audio-output")

    var muted = false {
        didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 1 }
    }

    var isPlaying: Bool { player.isPlaying }
    var playerVolume: Float { player.volume }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(player)
    }

    func handle(_ event: AudioEvent) {
        switch event {
        case let .started(sampleRate, channels, _):
            player.stop()
            playing = false
            queuedBeforePlay = 0
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)) else {
                log.error("audio: unsupported format \(sampleRate) Hz × \(channels)")
                format = nil
                return
            }
            format = fmt
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            if !engine.isRunning {
                do { try engine.start() }
                catch {
                    if !loggedStartFailure { log.error("audio: engine start failed: \(String(describing: error))"); loggedStartFailure = true }
                }
            }
        case let .pcm(frames, _):
            guard let format, engine.isRunning else { return }
            let channels = Int(format.channelCount)
            let count = AVAudioFrameCount(frames.count / channels)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                  let data = buffer.floatChannelData else { return }
            for c in 0 ..< channels {
                for i in 0 ..< Int(count) { data[c][i] = frames[i * channels + c] }
            }
            buffer.frameLength = count
            player.scheduleBuffer(buffer)
            if !playing {
                queuedBeforePlay += count
                if Double(queuedBeforePlay) >= Self.prebufferSeconds * format.sampleRate {
                    player.play()
                    playing = true
                }
            }
        case let .volume(levels):
            guestVolume = levels.isEmpty ? 1 : levels.reduce(0, +) / Float(levels.count)
            applyGuestLevel()
        case let .mute(on):
            guestMuted = on
            applyGuestLevel()
        case .stopped:
            player.stop()
            playing = false
            queuedBeforePlay = 0
        }
    }

    /// Session teardown. The engine is stopped too, so the device is released between sessions.
    func stop() {
        player.stop()
        playing = false
        queuedBeforePlay = 0
        format = nil
        if engine.isRunning { engine.stop() }
    }

    private func applyGuestLevel() { player.volume = guestMuted ? 0 : guestVolume }
}
