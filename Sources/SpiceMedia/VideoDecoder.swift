import CoreMedia
import CoreVideo
import VideoToolbox
import SpiceWire

/// Decoded stream output. BGRA rather than `CVPixelBuffer`/`IOSurface` because this crosses actor
/// boundaries (`StreamPlayer`, Task 11) and strict concurrency rules out handing either between actors.
public struct VideoFrame: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public enum VideoDecodeError: Error, Sendable {
    case format(String)
    case decode(OSStatus)
    case noKeyframe
}

/// One `VTDecompressionSession` path serving both stream codecs the spec requires. One per stream,
/// owned by the `StreamPlayer` actor (Task 11) — not `Sendable`, `~Copyable` like `ImageDecoder`.
public struct VideoDecoder: ~Copyable {
    private let codec: VideoCodecType
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var width = 0
    private var height = 0

    // H.264 parameter-set state, persisted across calls since the server need not resend them every frame.
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    public init(codec: VideoCodecType) {
        self.codec = codec
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// MJPEG: `data` is one complete JPEG. H.264: `data` is Annex-B NAL units; frames before the
    /// first SPS/PPS+IDR throw `.noKeyframe` — the server always opens a stream with a keyframe,
    /// so this tolerates loss by skipping rather than by crashing.
    public mutating func decode(_ data: [UInt8]) throws -> VideoFrame {
        switch codec {
        case .mjpeg: return try decodeMJPEG(data)
        case .h264: return try decodeH264(data)
        default: throw VideoDecodeError.format("unsupported stream codec \(codec)")
        }
    }

    // MARK: - MJPEG

    private mutating func decodeMJPEG(_ data: [UInt8]) throws -> VideoFrame {
        let dims = try Self.parseJPEGDimensions(data)
        if session == nil || dims.width != width || dims.height != height {
            var fmt: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_JPEG,
                                                          width: Int32(dims.width), height: Int32(dims.height),
                                                          extensions: nil, formatDescriptionOut: &fmt)
            guard status == noErr, let fmt else { throw VideoDecodeError.decode(status) }
            try createSession(formatDescription: fmt)
        }
        guard let formatDescription else { throw VideoDecodeError.format("no format description") }
        let sampleBuffer = try Self.makeSampleBuffer(data, formatDescription: formatDescription)
        return try decodeSampleBuffer(sampleBuffer)
    }

    /// Walks the JPEG marker chain to find a SOF segment's width/height, without trusting anything
    /// about segment lengths — a hostile or truncated header must throw, never trap or over-read.
    private static func parseJPEGDimensions(_ data: [UInt8]) throws -> (width: Int, height: Int) {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { throw VideoDecodeError.format("missing JPEG SOI") }
        var i = 2
        while i + 1 < data.count {
            guard data[i] == 0xFF else { throw VideoDecodeError.format("expected JPEG marker") }
            var j = i + 1
            while j < data.count, data[j] == 0xFF { j += 1 }
            guard j < data.count else { throw VideoDecodeError.format("truncated JPEG marker") }
            let marker = data[j]
            i = j + 1
            // Standalone markers (SOI, TEM, RSTn, EOI) carry no length field.
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9) {
                if marker == 0xD9 { throw VideoDecodeError.format("JPEG EOI before SOF") }
                continue
            }
            guard i + 1 < data.count else { throw VideoDecodeError.format("truncated JPEG segment length") }
            let length = Int(data[i]) << 8 | Int(data[i + 1])
            guard length >= 2, i + length <= data.count else { throw VideoDecodeError.format("bad JPEG segment length") }
            let isSOF = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isSOF {
                guard length >= 7 else { throw VideoDecodeError.format("JPEG SOF segment too short") }
                let h = Int(data[i + 3]) << 8 | Int(data[i + 4])
                let w = Int(data[i + 5]) << 8 | Int(data[i + 6])
                guard w > 0, h > 0 else { throw VideoDecodeError.format("zero JPEG dimensions") }
                return (w, h)
            }
            i += length
        }
        throw VideoDecodeError.format("no JPEG SOF marker found")
    }

    // MARK: - H.264

    private mutating func decodeH264(_ data: [UInt8]) throws -> VideoFrame {
        var vclNALs: [[UInt8]] = []
        for nal in Self.splitAnnexBNALs(data) {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            case 1, 5: vclNALs.append(nal)   // a frame can be split across multiple slices
            default: break
            }
        }
        if let sps, let pps {
            let fmt = try Self.makeH264FormatDescription(sps: sps, pps: pps)
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            if session == nil || Int(dims.width) != width || Int(dims.height) != height {
                try createSession(formatDescription: fmt)
            }
        }
        // No session yet means no SPS/PPS+IDR has ever landed — tolerate loss by dropping, not crashing.
        guard session != nil, let formatDescription else { throw VideoDecodeError.noKeyframe }
        guard !vclNALs.isEmpty else { throw VideoDecodeError.noKeyframe }   // parameter-sets-only delivery
        // AVCC packs every slice of the frame into one sample, each with its own length prefix —
        // dropping all but the last slice (as an earlier version of this did) silently corrupts
        // any frame an encoder splits into multiple slices.
        let avcc = vclNALs.reduce(into: [UInt8]()) { $0.append(contentsOf: Self.avccPacket(from: $1)) }
        let sampleBuffer = try Self.makeSampleBuffer(avcc, formatDescription: formatDescription)
        return try decodeSampleBuffer(sampleBuffer)
    }

    /// Splits Annex-B on 3- or 4-byte start codes and returns each NAL's payload (header + RBSP,
    /// start code stripped). Bounds-checked throughout — the input is server-controlled.
    private static func splitAnnexBNALs(_ data: [UInt8]) -> [[UInt8]] {
        var starts: [Int] = []
        var i = 0
        while i + 2 < data.count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 { starts.append(i); i += 3 } else { i += 1 }
        }
        guard !starts.isEmpty else { return [] }
        var nals: [[UInt8]] = []
        for (idx, start) in starts.enumerated() {
            let payloadStart = start + 3
            let end = idx + 1 < starts.count ? starts[idx + 1] : data.count
            guard payloadStart <= end else { continue }
            nals.append(Array(data[payloadStart ..< end]))
        }
        return nals
    }

    private static func makeH264FormatDescription(sps: [UInt8], pps: [UInt8]) throws -> CMFormatDescription {
        var fmt: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuf -> OSStatus in
            pps.withUnsafeBufferPointer { ppsBuf -> OSStatus in
                guard let spsBase = spsBuf.baseAddress, let ppsBase = ppsBuf.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!, parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
                    }
                }
            }
        }
        guard status == noErr, let fmt else { throw VideoDecodeError.decode(status) }
        return fmt
    }

    private static func avccPacket(from nal: [UInt8]) -> [UInt8] {
        let length = UInt32(nal.count)
        var out: [UInt8] = [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        out.append(contentsOf: nal)
        return out
    }

    // MARK: - Session + decode plumbing shared by both codecs

    private mutating func createSession(formatDescription fmt: CMFormatDescription) throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let destinationAttributes = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)] as CFDictionary
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
                                                   decoderSpecification: nil, imageBufferAttributes: destinationAttributes,
                                                   outputCallback: nil, decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else { throw VideoDecodeError.decode(status) }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        session = newSession
        formatDescription = fmt
        width = Int(dims.width)
        height = Int(dims.height)
    }

    private static func makeSampleBuffer(_ bytes: [UInt8], formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        guard !bytes.isEmpty else { throw VideoDecodeError.format("empty frame payload") }
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                                offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &blockBuffer)
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { throw VideoDecodeError.decode(createStatus) }
        let copyStatus = bytes.withUnsafeBufferPointer { buf -> OSStatus in
            guard let base = buf.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw VideoDecodeError.decode(copyStatus) }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = bytes.count
        let sbStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
                                             makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                                             sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                             sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard sbStatus == noErr, let sampleBuffer else { throw VideoDecodeError.decode(sbStatus) }
        return sampleBuffer
    }

    /// Empty decode flags make this call synchronous — the output handler runs and returns before
    /// `VTDecompressionSessionDecodeFrame` itself returns, so the write into `outcome` below can
    /// never race a read of it. `VTDecompressionOutputHandler` is declared `@Sendable`, though, so
    /// the compiler can't see that guarantee and flags the capture anyway
    /// (`#SendableClosureCaptures`) — that warning is expected here and does not indicate a real
    /// race. It is left as a warning deliberately: routing the write through a pointer instead does
    /// not actually avoid it, since neither `UnsafeMutablePointer<T>` (its `Sendable` conformance is
    /// unconditionally unavailable in the standard library) nor `UnsafeMutableRawPointer` (does not
    /// conform to `Sendable` at all) can carry the capture without the same diagnostic reappearing
    /// one level down — confirmed by trying both. The remaining alternatives (a lock, `@unchecked
    /// Sendable`, `nonisolated(unsafe)`) are exactly what this module must not use. Do not "fix"
    /// this warning with one of those; the fix would introduce more risk than the warning itself.
    private mutating func decodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws -> VideoFrame {
        guard let session else { throw VideoDecodeError.format("no active decompression session") }
        let outWidth = width, outHeight = height
        var outcome: Result<VideoFrame, VideoDecodeError>?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            if status != noErr { outcome = .failure(.decode(status)); return }
            guard let imageBuffer else { outcome = .failure(.format("decoder returned no image")); return }
            do { outcome = .success(try Self.copyBGRA(imageBuffer, width: outWidth, height: outHeight)) }
            catch let e as VideoDecodeError { outcome = .failure(e) }
            catch { outcome = .failure(.format("\(error)")) }
        }
        guard status == noErr else { throw VideoDecodeError.decode(status) }
        switch outcome {
        case .success(let frame): return frame
        case .failure(let error): throw error
        case nil: throw VideoDecodeError.format("decode produced no output")
        }
    }

    private static func copyBGRA(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> VideoFrame {
        guard width > 0, height > 0 else { throw VideoDecodeError.format("invalid frame dimensions") }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw VideoDecodeError.format("pixel buffer lock failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw VideoDecodeError.format("pixel buffer has no base address") }
        let bufWidth = CVPixelBufferGetWidth(pixelBuffer), bufHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard bufWidth >= width, bufHeight >= height else { throw VideoDecodeError.format("pixel buffer smaller than expected frame") }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { dst in
            for y in 0 ..< height {
                UnsafeMutableRawPointer(dst.baseAddress!.advanced(by: y * width * 4))
                    .copyMemory(from: src + y * bytesPerRow, byteCount: width * 4)
            }
        }
        return VideoFrame(width: width, height: height, pixels: out)
    }
}
