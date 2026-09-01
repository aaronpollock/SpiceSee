import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import SpiceWire
import SpiceMedia
@testable import SpiceCore
@testable import SpiceKit

/// Solid-color JPEG, just enough for `VideoDecoder` to produce a frame. `Tests/SpiceMediaTests`
/// has its own copy; SPM test targets cannot import one another's sources.
private func jpegFrame(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> [UInt8] {
    var px = [UInt8](repeating: 255, count: width * height * 4)
    for i in stride(from: 0, to: px.count, by: 4) { px[i] = b; px[i + 1] = g; px[i + 2] = r }
    let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return [UInt8](data as Data)
}

/// A main channel whose MAIN_INIT and CHANNELS_LIST advertise exactly one display channel, id 0.
private func mainBytesWithDisplay() throws -> [UInt8] {
    var mi = SpiceWriter(); [1, 1, SpiceMouseMode.server, SpiceMouseMode.server, 0, 10, 0, 0].forEach { mi.u32($0) }
    var cl = SpiceWriter(); cl.u32(1); cl.u8(ChannelType.display.rawValue); cl.u8(0)
    return try fakeLink(body: frame(MainServerMsg.`init`.rawValue, mi.bytes) + frame(MainServerMsg.channelsList.rawValue, cl.bytes))
}

/// A display channel that opens a stream, sends one MJPEG frame, and destroys it must surface
/// exactly streamFrame + streamDestroyed session events — and the canvas must never see them.
@Test func streamMessagesRouteToPlayerNotCanvas() async throws {
    var body: [UInt8] = []
    var sc = SpiceWriter()
    sc.u32(0); sc.u32(800); sc.u32(600); sc.u32(32); sc.u32(1)
    body += frame(DisplayServerMsg.surfaceCreate.rawValue, sc.bytes)
    var cr = SpiceWriter()
    cr.u32(0); cr.u32(7); cr.u8(StreamFlags.topDown); cr.u8(VideoCodecType.mjpeg.rawValue); cr.u64(0)
    cr.u32(64); cr.u32(48); cr.u32(64); cr.u32(48)
    cr.i32(0); cr.i32(0); cr.i32(48); cr.i32(64); cr.u8(0)
    body += frame(DisplayServerMsg.streamCreate.rawValue, cr.bytes)
    // mmTime is far ahead of the mm clock seeded from MAIN_INIT (0): StreamPlayer drops a frame
    // more than 80ms "late" against wall-clock elapsed time, and a full `swift test` run under
    // heavy parallel load can easily take longer than that to reach this message. A large mmTime
    // keeps this test about routing, not about racing the scheduler.
    let jpeg = try jpegFrame(width: 64, height: 48, r: 5, g: 5, b: 5)
    var da = SpiceWriter(); da.u32(7); da.u32(60_000); da.u32(UInt32(jpeg.count)); da.bytes(jpeg)
    body += frame(DisplayServerMsg.streamData.rawValue, da.bytes)
    var de = SpiceWriter(); de.u32(7)
    body += frame(DisplayServerMsg.streamDestroy.rawValue, de.bytes)

    let main = InMemoryTransport(input: try mainBytesWithDisplay())
    let display = InMemoryTransport(input: try fakeLink(body: body))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return main
        case .display: return display
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    var sawFrame = false, sawDestroy = false, sawUnsupportedCanvas = false
    for await e in session.events {
        switch e {
        case let .streamFrame(f, displayID: 0): sawFrame = f.streamID == 7 && f.width == 64
        case .streamDestroyed(id: 7, displayID: 0): sawDestroy = true
        case .canvas(.unsupported, displayID: _): sawUnsupportedCanvas = true
        case .disconnected: break
        default: continue
        }
        if case .disconnected = e { break }
    }
    #expect(sawFrame && sawDestroy && !sawUnsupportedCanvas)
}
