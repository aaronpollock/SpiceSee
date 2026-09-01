/// The playback channel (`spice.proto` PlaybackChannel), server → client. Ids start at 101 like
/// every channel's first message; layouts follow spice-gtk's channel-playback.c.
public enum PlaybackServerMsg: UInt16, Sendable {
    case data = 101, mode, start, stop, volume, mute, latency
}

/// `SPICE_PLAYBACK_CAP_*` from spice/protocol.h.
public enum PlaybackCap {
    public static let celt051: UInt32 = 0, volume: UInt32 = 1, latency: UInt32 = 2, opus: UInt32 = 3
}

/// `SPICE_AUDIO_DATA_MODE_*`; 0 is INVALID and deliberately absent.
public enum AudioDataMode: UInt16, Sendable { case raw = 1, celt051 = 2, opus = 3 }

/// `SPICE_AUDIO_FMT_*`; S16 is the only format the protocol defines.
public enum AudioFormat { public static let s16: UInt16 = 1 }

public struct PlaybackStart: Sendable, Equatable {
    public var channels: UInt32, format: UInt16, frequency: UInt32, time: UInt32
    public init(channels: UInt32, format: UInt16, frequency: UInt32, time: UInt32) {
        self.channels = channels; self.format = format; self.frequency = frequency; self.time = time
    }
    init(reader r: inout SpiceReader) throws {
        channels = try r.u32(); format = try r.u16(); frequency = try r.u32(); time = try r.u32()
    }
}

public enum PlaybackMessage: Sendable, Equatable {
    case data(time: UInt32, payload: [UInt8])
    /// `mode` is the raw `SPICE_AUDIO_DATA_MODE` value: rejecting an unknown or unsupported codec is
    /// the consumer's decision, not a parse failure.
    case mode(time: UInt32, mode: UInt16)
    case start(PlaybackStart)
    case stop
    case volume([UInt16])
    case mute(Bool)
    case latency(ms: UInt32)
    case other(type: UInt16)

    public init(type: UInt16, payload: [UInt8]) throws {
        var r = SpiceReader(payload)
        switch PlaybackServerMsg(rawValue: type) {
        case .data:
            let time = try r.u32()
            self = .data(time: time, payload: try r.bytes(r.remaining))
        case .mode:
            let time = try r.u32()
            self = .mode(time: time, mode: try r.u16())
        case .start: self = .start(try PlaybackStart(reader: &r))
        case .stop: self = .stop
        case .volume:
            let n = Int(try r.u8())
            self = .volume(try (0 ..< n).map { _ in try r.u16() })
        case .mute: self = .mute(try r.u8() != 0)
        case .latency: self = .latency(ms: try r.u32())
        case nil: self = .other(type: type)
        }
    }
}
