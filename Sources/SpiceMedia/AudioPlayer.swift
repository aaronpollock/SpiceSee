import os
import SpiceWire

/// The video rule, reused: a packet this far behind the mm clock is dropped before decode.
private let maxLatenessMs: Int64 = 80

public enum AudioEvent: Sendable, Equatable {
    /// `opus` is the codec the server negotiated (PLAYBACK_MODE), not whether local decode
    /// succeeded — the probe prints it as MODE=OPUS.
    case started(sampleRate: Int, channels: Int, opus: Bool)
    case pcm(frames: [Float], mmTime: UInt32)
    case volume([Float])
    case mute(Bool)
    case stopped
}

/// Decodes the playback channel into Float32 frames and gates late packets against the mm clock.
/// A pure decode-and-gate stage: it holds no jitter buffer, so the output owns the ~50 ms
/// prebuffer, and a test can drive this actor with a synthetic clock.
public actor AudioPlayer {
    public nonisolated let events: AsyncStream<AudioEvent>
    private let cont: AsyncStream<AudioEvent>.Continuation
    private let opusAvailable: Bool
    private var mode: AudioDataMode?
    private var unsupportedModeLogged = false
    private var format: (sampleRate: Int, channels: Int)?
    private var decoder: OpusDecoder?
    private var mmBase: (serverTime: UInt32, at: ContinuousClock.Instant)?
    private let log = Logger(subsystem: "com.spicesee", category: "audio")

    /// Test-only counters — `internal`, reachable through `@testable import` only. Frame counts
    /// alone cannot separate "dropped before decode" from "decoded and threw".
    private(set) var decodeAttempts: UInt32 = 0
    private(set) var droppedLate: UInt32 = 0

    public init(opusAvailable: Bool) {
        self.opusAvailable = opusAvailable
        (events, cont) = AsyncStream.makeStream(of: AudioEvent.self, bufferingPolicy: .unbounded)
    }

    public func finish() { cont.finish() }

    public func setMMTime(_ serverTime: UInt32) { mmBase = (serverTime, .now) }

    private func serverNow() -> UInt32? {
        guard let mmBase else { return nil }
        let elapsedMs = mmBase.at.duration(to: .now).milliseconds
        return mmBase.serverTime &+ UInt32(clamping: elapsedMs)
    }

    public func handle(_ message: PlaybackMessage) {
        switch message {
        case let .mode(_, raw):
            mode = AudioDataMode(rawValue: raw)
            unsupportedModeLogged = false          // a fresh MODE is fresh news: re-arm the one-shot
            if mode == nil || mode == .celt051 {
                log.notice("playback: unsupported audio mode \(raw); dropping data")
                unsupportedModeLogged = true
            }
        case let .start(s):
            // Wire-controlled u32s: 2^30 channels would trap `UInt32(channels * 4)` in the decoder's
            // PCM format, and anything merely large allocates 5760 × channels floats per packet.
            guard (1...8).contains(s.channels), (8_000...192_000).contains(s.frequency), s.format == AudioFormat.s16 else {
                log.error("playback: implausible START \(s.frequency) Hz × \(s.channels) fmt \(s.format); ignoring")
                return
            }
            format = (Int(s.frequency), Int(s.channels))
            decoder = nil
            let usesOpus = mode == .opus
            if usesOpus, opusAvailable {
                do { decoder = try OpusDecoder(sampleRate: Double(s.frequency), channels: Int(s.channels)) }
                catch { log.error("playback: Opus decoder unavailable: \(String(describing: error), privacy: .public); dropping Opus data") }
            }
            cont.yield(.started(sampleRate: Int(s.frequency), channels: Int(s.channels), opus: usesOpus))
        case let .data(time, payload):
            guard format != nil else { return }
            guard let mode else {
                if !unsupportedModeLogged {
                    log.notice("playback: DATA before any MODE; dropping until the server sends one")
                    unsupportedModeLogged = true
                }
                return
            }
            if let now = serverNow(), Int64(now) - Int64(time) > maxLatenessMs {
                droppedLate += 1
                if droppedLate == 1 || droppedLate % 100 == 0 {
                    log.notice("playback: dropped \(self.droppedLate) late packets (\(Int64(now) - Int64(time)) ms behind the mm clock)")
                }
                return
            }
            switch mode {
            case .raw:
                cont.yield(.pcm(frames: Self.floats(fromS16: payload), mmTime: time))
            case .opus:
                guard let decoder else { return }
                decodeAttempts += 1
                do {
                    let frames = try decoder.decode(payload)
                    if !frames.isEmpty { cont.yield(.pcm(frames: frames, mmTime: time)) }
                } catch { log.error("playback: Opus decode failed: \(String(describing: error), privacy: .public); packet skipped") }
            case .celt051:
                break
            }
        case let .volume(levels):
            cont.yield(.volume(levels.map { Float($0) / 65535 }))
        case let .mute(on):
            cont.yield(.mute(on))
        case .stop:
            format = nil
            decoder = nil
            cont.yield(.stopped)
        case let .latency(ms):
            log.debug("playback: server latency hint \(ms) ms")
        case .other:
            break
        }
    }

    private static func floats(fromS16 bytes: [UInt8]) -> [Float] {
        var out = [Float](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let s = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            out.append(Float(s) / 32768)
            i += 2
        }
        return out
    }
}
