import AudioToolbox

public struct AudioDecodeError: Error, Sendable { public var status: Int32 }

/// Opus → Float32 PCM through AudioToolbox — Apple ships the decoder, so nothing is vendored.
/// One converter per stream (recreated on every PLAYBACK_START), fed one packet per `decode`.
/// Actor-confined by its owner; not Sendable, like `VideoDecoder`.
public final class OpusDecoder {
    /// Returned by the input callback once its single packet is consumed. Fill then returns it too,
    /// with whatever frames were decoded; that is success here, not failure.
    private static let noMoreData: OSStatus = 0x6E6F6D6F   // 'nomo'

    private let converter: AudioConverterRef
    private let channels: Int
    private let maxFrames = 5760                          // Opus's largest frame: 120 ms at 48 kHz

    /// Whether this macOS decodes Opus. False → the caller must not advertise the capability.
    public static func isAvailable(sampleRate: Double = 48000, channels: Int = 2) -> Bool {
        var input = Self.opusFormat(sampleRate: sampleRate, channels: channels)
        var output = Self.pcmFormat(sampleRate: sampleRate, channels: channels)
        var ref: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &ref) == noErr, let ref else { return false }
        AudioConverterDispose(ref)
        return true
    }

    public init(sampleRate: Double, channels: Int) throws {
        var input = Self.opusFormat(sampleRate: sampleRate, channels: channels)
        var output = Self.pcmFormat(sampleRate: sampleRate, channels: channels)
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &ref)
        guard status == noErr, let ref else { throw AudioDecodeError(status: status) }
        converter = ref
        self.channels = channels
    }

    deinit { AudioConverterDispose(converter) }

    private static func opusFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        // mFramesPerPacket 0 = variable: SPICE sends 480-frame packets, libopus fixtures may differ,
        // and the spike showed the decoder needs no hint either way.
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                    mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
    }

    private static func pcmFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        let bytes = UInt32(channels * 4)
        return AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                                           mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// One packet in, its interleaved Float32 frames out. The first packet of a stream comes back
    /// short by the pre-skip; garbage comes back as an error or as nothing; an empty packet decodes
    /// to nothing without asking the converter (it would otherwise see a nil base pointer).
    public func decode(_ packet: [UInt8]) throws -> [Float] {
        guard !packet.isEmpty else { return [] }
        // Owns its packet bytes and packet description as explicitly allocated storage, freed in
        // deinit, rather than pointers borrowed from `withUnsafe...` closures — those pointers are
        // only valid inside their closure, but the input callback below hands them to the converter
        // to read *after* this call returns from them.
        final class Feed {
            let buffer: UnsafeMutableRawBufferPointer
            let descPtr: UnsafeMutablePointer<AudioStreamPacketDescription>
            var consumed = false
            init(_ packet: [UInt8]) {
                let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: packet.count, alignment: 1)
                packet.withUnsafeBytes { bytes.copyMemory(from: $0) }
                buffer = bytes
                descPtr = .allocate(capacity: 1)
                descPtr.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            }
            deinit { buffer.deallocate(); descPtr.deallocate() }
        }
        let feed = Feed(packet)
        let input: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, userData in
            // userData is always the pointer we handed AudioConverterFillComplexBuffer below, so
            // force-unwrapping it here reflects that guarantee rather than an unchecked assumption.
            let feed = Unmanaged<Feed>.fromOpaque(userData!).takeUnretainedValue()
            guard !feed.consumed else { ioPackets.pointee = 0; return OpusDecoder.noMoreData }
            feed.consumed = true
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mData = feed.buffer.baseAddress
            ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.buffer.count)
            ioData.pointee.mBuffers.mNumberChannels = 0
            outDesc?.pointee = feed.descPtr
            ioPackets.pointee = 1
            return noErr
        }
        var out = [Float](repeating: 0, count: maxFrames * channels)
        var frames = UInt32(maxFrames)
        // `feed` is otherwise last used to build the opaque pointer below, which is not a formal
        // use ARC tracks — without this, the compiler is free to release it before Fill runs.
        let status: OSStatus = withExtendedLifetime(feed) {
            out.withUnsafeMutableBufferPointer { p in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(p.count * 4), mData: UnsafeMutableRawPointer(p.baseAddress)))
                return AudioConverterFillComplexBuffer(converter, input, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
            }
        }
        guard status == noErr || status == Self.noMoreData else { throw AudioDecodeError(status: status) }
        return Array(out.prefix(Int(frames) * channels))
    }
}
