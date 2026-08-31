import Testing
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import SpiceWire
@testable import SpiceMedia

/// Fills the top half of the image with `top` and the bottom half with `bottom`, so decoded output
/// can be checked for both channel order (BGRA vs RGBA) and row order (top-down vs bottom-up) —
/// a solid single-color frame can't distinguish either.
private func jpegFrame(width: Int, height: Int, top: (r: UInt8, g: UInt8, b: UInt8), bottom: (r: UInt8, g: UInt8, b: UInt8)) throws -> [UInt8] {
    var px = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0 ..< height {
        let c = y < height / 2 ? top : bottom
        for x in 0 ..< width {
            let i = (y * width + x) * 4
            px[i] = c.b; px[i + 1] = c.g; px[i + 2] = c.r
        }
    }
    let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return [UInt8](data as Data)
}

/// Encodes N BGRA gradient frames to Annex-B H.264 using VideoToolbox, for round-tripping through
/// `VideoDecoder`. This is the inverse of the decoder's AVCC/Annex-B conversion, which is exactly
/// why the round-trip test built from it is self-consistent rather than a real-server proof.
private enum H264TestEncoder {
    static func encodeGradient(width: Int, height: Int, frames: Int) throws -> [[UInt8]] {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                 codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                 imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                 outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw VideoDecodeError.decode(status) }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)

        var annexB: [[UInt8]] = []
        for f in 0 ..< frames {
            var pixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else { throw VideoDecodeError.format("pixel buffer") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let buf = base.assumingMemoryBound(to: UInt8.self)
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let i = y * bytesPerRow + x * 4
                        let shade = UInt8((x + y + f * 8) % 256)
                        buf[i] = shade; buf[i + 1] = shade; buf[i + 2] = shade; buf[i + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let pts = CMTime(value: CMTimeValue(f), timescale: 30)
            var encoded: [[UInt8]] = []
            let encodeError = NSErrorPointer(nilLiteral: ())
            _ = encodeError
            let semaphore = DispatchSemaphore(value: 0)
            var encodeStatus: OSStatus = noErr
            VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                             duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { st, _, sampleBuffer in
                encodeStatus = st
                if let sampleBuffer, let nals = try? annexBNALs(from: sampleBuffer) { encoded = nals }
                semaphore.signal()
            }
            semaphore.wait()
            guard encodeStatus == noErr else { throw VideoDecodeError.decode(encodeStatus) }
            annexB.append(encoded.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) })
        }
        return annexB
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private static func annexBNALs(from sampleBuffer: CMSampleBuffer) throws -> [[UInt8]] {
        var out: [[UInt8]] = []
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var index = 0
            while true {
                var ptr: UnsafePointer<UInt8>?
                var length = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index,
                                                                                 parameterSetPointerOut: &ptr,
                                                                                 parameterSetSizeOut: &length,
                                                                                 parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard status == noErr, let ptr else { break }
                out.append(startCode + Array(UnsafeBufferPointer(start: ptr, count: length)))
                index += 1
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { throw VideoDecodeError.format("no data buffer") }
        var length = 0, totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { throw VideoDecodeError.format("block buffer pointer") }
        let bytes = dataPointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) { UnsafeBufferPointer(start: $0, count: totalLength) }
        var offset = 0
        while offset + 4 <= bytes.count {
            let nalLength = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= bytes.count else { break }
            out.append(startCode + Array(bytes[offset ..< offset + nalLength]))
            offset += nalLength
        }
        return out
    }
}

@Test func mjpegDecodesToBGRA() throws {
    var d = VideoDecoder(codec: .mjpeg)
    let top = (r: UInt8(255), g: UInt8(0), b: UInt8(0))
    let bottom = (r: UInt8(0), g: UInt8(0), b: UInt8(255))
    let frame = try d.decode(try jpegFrame(width: 64, height: 48, top: top, bottom: bottom))
    #expect(frame.width == 64 && frame.height == 48)
    #expect(frame.pixels.count == 64 * 48 * 4)

    // Row 2 (well inside the top half) must read back as the top color, and row (height-3)
    // (well inside the bottom half) as the bottom color — this fails if rows are flipped.
    let topRowOffset = (2 * 64 + 2) * 4
    let bottomRowOffset = ((48 - 3) * 64 + 2) * 4
    // BGRA: index 0 = blue, 1 = green, 2 = red. Wrong channel order (e.g. RGBA) fails these.
    #expect(abs(Int(frame.pixels[topRowOffset + 0]) - Int(top.b)) < 16)
    #expect(abs(Int(frame.pixels[topRowOffset + 1]) - Int(top.g)) < 16)
    #expect(abs(Int(frame.pixels[topRowOffset + 2]) - Int(top.r)) < 16)
    #expect(abs(Int(frame.pixels[bottomRowOffset + 0]) - Int(bottom.b)) < 16)
    #expect(abs(Int(frame.pixels[bottomRowOffset + 1]) - Int(bottom.g)) < 16)
    #expect(abs(Int(frame.pixels[bottomRowOffset + 2]) - Int(bottom.r)) < 16)
}

@Test func h264RoundTripsThroughVideoToolbox() throws {
    // SELF-CONSISTENT: encodes with VT and decodes with VT. Real-server H.264 remains unverified
    // (see "What cannot be verified"). What this does prove: Annex-B parsing, SPS/PPS extraction,
    // AVCC conversion, session lifecycle, BGRA output geometry.
    let annexB = try H264TestEncoder.encodeGradient(width: 64, height: 48, frames: 3)
    var d = VideoDecoder(codec: .h264)
    var decoded = 0
    for frame in annexB {
        if let f = try? d.decode(frame) { decoded += 1; #expect(f.width == 64 && f.height == 48) }
    }
    #expect(decoded >= 2)     // the first delivery can be parameter-sets-only
}

@Test func garbageInputThrowsNotTraps() {
    var d = VideoDecoder(codec: .mjpeg)
    #expect(throws: (any Error).self) { _ = try d.decode([0xDE, 0xAD, 0xBE, 0xEF]) }
    var h = VideoDecoder(codec: .h264)
    #expect(throws: (any Error).self) { _ = try h.decode([0, 0, 0, 1, 0x41, 0xFF]) }  // P-slice before SPS
}

@Test func truncatedJPEGSOFThrowsNotTraps() {
    var d = VideoDecoder(codec: .mjpeg)
    // Valid SOI, then a SOF0 marker whose declared segment length reaches past the buffer end.
    #expect(throws: (any Error).self) { _ = try d.decode([0xFF, 0xD8, 0xFF, 0xC0, 0xFF, 0xFF]) }
}

@Test func h264TruncatedStartCodeDoesNotTrap() {
    var h = VideoDecoder(codec: .h264)
    #expect(throws: (any Error).self) { _ = try h.decode([0, 0, 1]) }   // start code with no NAL bytes after it
}
