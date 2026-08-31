/// data_size on stream frames is server-controlled and unbounded in the protocol; capped like images
/// so a hostile size is refused before any allocation.
private let maxStreamDataSize = 1 << 26

public enum VideoCodecType: UInt8, Sendable { case mjpeg = 1, vp8, h264, vp9, h265 }
public enum StreamFlags { public static let topDown: UInt8 = 1 }

public struct StreamCreate: Sendable, Equatable {
    public var surfaceID: UInt32, id: UInt32, flags: UInt8, codec: VideoCodecType
    public var streamWidth: UInt32, streamHeight: UInt32, srcWidth: UInt32, srcHeight: UInt32
    public var dest: SpiceRect, clip: SpiceClip

    public init(surfaceID: UInt32, id: UInt32, flags: UInt8, codec: VideoCodecType,
                streamWidth: UInt32, streamHeight: UInt32, srcWidth: UInt32, srcHeight: UInt32,
                dest: SpiceRect, clip: SpiceClip) {
        self.surfaceID = surfaceID; self.id = id; self.flags = flags; self.codec = codec
        self.streamWidth = streamWidth; self.streamHeight = streamHeight
        self.srcWidth = srcWidth; self.srcHeight = srcHeight
        self.dest = dest; self.clip = clip
    }

    init(reader r: inout SpiceReader) throws {
        surfaceID = try r.u32(); id = try r.u32(); flags = try r.u8()
        let c = try r.u8()
        guard let codecType = VideoCodecType(rawValue: c) else { throw WireError.badValue(field: "codec_type", value: UInt64(c)) }
        codec = codecType
        _ = try r.u64()   // stamp: unused by the client
        streamWidth = try r.u32(); streamHeight = try r.u32(); srcWidth = try r.u32(); srcHeight = try r.u32()
        dest = try SpiceRect(reader: &r); clip = try SpiceClip(reader: &r)
    }
}

public struct StreamData: Sendable, Equatable {
    /// Swift 6's synthesized `Equatable` doesn't extend to a named 3-element tuple field on this
    /// toolchain, so `sized` uses a small struct instead of the tuple the interface sketch shows.
    public struct SizedInfo: Sendable, Equatable {
        public var width: UInt32, height: UInt32, dest: SpiceRect
        public init(width: UInt32, height: UInt32, dest: SpiceRect) { self.width = width; self.height = height; self.dest = dest }
    }
    public var id: UInt32, mmTime: UInt32, data: [UInt8]
    public var sized: SizedInfo?

    public init(id: UInt32, mmTime: UInt32, data: [UInt8], sized: SizedInfo?) {
        self.id = id; self.mmTime = mmTime; self.data = data; self.sized = sized
    }

    init(reader r: inout SpiceReader, sized isSized: Bool) throws {
        id = try r.u32(); mmTime = try r.u32()
        if isSized {
            let width = try r.u32(); let height = try r.u32()
            let dest = try SpiceRect(reader: &r)
            let size = try r.u32()
            guard size <= maxStreamDataSize, Int(size) <= r.remaining else {
                throw WireError.badValue(field: "data_size", value: UInt64(size))
            }
            data = try r.bytes(Int(size))
            sized = SizedInfo(width: width, height: height, dest: dest)
        } else {
            let size = try r.u32()
            guard size <= maxStreamDataSize, Int(size) <= r.remaining else {
                throw WireError.badValue(field: "data_size", value: UInt64(size))
            }
            data = try r.bytes(Int(size))
            sized = nil
        }
    }
}

public struct StreamActivateReport: Sendable, Equatable {
    public var streamID: UInt32, uniqueID: UInt32, maxWindowSize: UInt32, timeoutMs: UInt32

    public init(streamID: UInt32, uniqueID: UInt32, maxWindowSize: UInt32, timeoutMs: UInt32) {
        self.streamID = streamID; self.uniqueID = uniqueID; self.maxWindowSize = maxWindowSize; self.timeoutMs = timeoutMs
    }

    init(reader r: inout SpiceReader) throws {
        streamID = try r.u32(); uniqueID = try r.u32(); maxWindowSize = try r.u32(); timeoutMs = try r.u32()
    }
}

public struct StreamReport: Sendable, Equatable {
    public var streamID: UInt32, uniqueID: UInt32
    public var startFrameMMTime: UInt32, endFrameMMTime: UInt32
    public var numFrames: UInt32, numDrops: UInt32
    public var lastFrameDelay: Int32, audioDelay: UInt32

    public init(streamID: UInt32, uniqueID: UInt32, startFrameMMTime: UInt32, endFrameMMTime: UInt32,
                numFrames: UInt32, numDrops: UInt32, lastFrameDelay: Int32, audioDelay: UInt32) {
        self.streamID = streamID; self.uniqueID = uniqueID
        self.startFrameMMTime = startFrameMMTime; self.endFrameMMTime = endFrameMMTime
        self.numFrames = numFrames; self.numDrops = numDrops
        self.lastFrameDelay = lastFrameDelay; self.audioDelay = audioDelay
    }
}

extension ClientMessage {
    public static func streamReport(_ r: StreamReport) -> [UInt8] {
        var w = SpiceWriter()
        w.u32(r.streamID); w.u32(r.uniqueID)
        w.u32(r.startFrameMMTime); w.u32(r.endFrameMMTime)
        w.u32(r.numFrames); w.u32(r.numDrops)
        w.i32(r.lastFrameDelay); w.u32(r.audioDelay)
        return w.bytes
    }
}
