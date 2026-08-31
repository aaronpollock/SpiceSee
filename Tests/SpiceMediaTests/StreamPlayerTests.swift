import Testing
import SpiceWire
@testable import SpiceMedia

private func mjpegCreate(id: UInt32 = 1, flags: UInt8 = StreamFlags.topDown, dest: SpiceRect = SpiceRect(top: 0, left: 0, bottom: 48, right: 64)) -> StreamCreate {
    StreamCreate(surfaceID: 0, id: id, flags: flags, codec: .mjpeg,
                 streamWidth: 64, streamHeight: 48, srcWidth: 64, srcHeight: 48, dest: dest, clip: .none)
}

@Test func frameCarriesGeometryAtArrival() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate())
    await p.handle(data: StreamData(id: 1, mmTime: 0, data: try jpegFrame(width: 64, height: 48, r: 9, g: 9, b: 9), sized: nil))
    await p.handle(clipChange: 1, clip: .rects([SpiceRect(top: 0, left: 0, bottom: 10, right: 10)]))
    await p.finish()
    var frames: [StreamFrame] = []
    for await e in p.events { if case let .frame(f) = e { frames.append(f) } }
    #expect(frames.count == 1)
    #expect(frames[0].clip == .none)          // the clip change came after this frame
    #expect(frames[0].dest.width == 64)
}

@Test func lateFramesDropBeforeDecode() async throws {
    let p = StreamPlayer()
    await p.setMMTime(10_000)
    await p.handle(create: mjpegCreate())
    // 5 seconds behind the mm clock: must be dropped without touching the decoder,
    // so garbage data here must NOT produce a decode error.
    await p.handle(data: StreamData(id: 1, mmTime: 5_000, data: [0xFF], sized: nil))
    await p.handle(data: StreamData(id: 1, mmTime: 10_000, data: try jpegFrame(width: 64, height: 48, r: 1, g: 1, b: 1), sized: nil))
    await p.finish()
    var frames = 0
    for await e in p.events { if case .frame = e { frames += 1 } }
    #expect(frames == 1)
}

@Test func reportEmittedAtWindow() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate())
    await p.handle(activateReport: StreamActivateReport(streamID: 1, uniqueID: 42, maxWindowSize: 2, timeoutMs: 60_000))
    let jpeg = try jpegFrame(width: 64, height: 48, r: 0, g: 0, b: 0)
    await p.handle(data: StreamData(id: 1, mmTime: 100, data: jpeg, sized: nil))
    await p.handle(data: StreamData(id: 1, mmTime: 133, data: jpeg, sized: nil))
    await p.finish()
    var reports: [StreamReport] = []
    for await e in p.events { if case let .report(r) = e { reports.append(r) } }
    #expect(reports.count == 1)
    #expect(reports[0].uniqueID == 42 && reports[0].numFrames == 2 && reports[0].numDrops == 0)
    #expect(reports[0].startFrameMMTime == 100 && reports[0].endFrameMMTime == 133)
    #expect(reports[0].audioDelay == .max)
}

@Test func sizedFrameMovesTheStream() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate())
    let newDest = SpiceRect(top: 100, left: 100, bottom: 148, right: 164)
    await p.handle(data: StreamData(id: 1, mmTime: 0,
                                    data: try jpegFrame(width: 64, height: 48, r: 2, g: 2, b: 2),
                                    sized: .init(width: 64, height: 48, dest: newDest)))
    await p.finish()
    for await e in p.events { if case let .frame(f) = e { #expect(f.dest == newDest) } }
}

@Test func destroyStopsEmission() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate())
    await p.handle(destroy: 1)
    await p.handle(data: StreamData(id: 1, mmTime: 0, data: [1, 2, 3], sized: nil))  // stale data after destroy
    await p.finish()
    var destroyed = false, frames = 0
    for await e in p.events {
        if case .destroyed(1) = e { destroyed = true }
        if case .frame = e { frames += 1 }
    }
    #expect(destroyed && frames == 0)
}

// MARK: - Additional coverage for the rulings this task binds to (not in the brief's own sketches)

/// Ruling 4: a codec other than MJPEG/H.264 must be logged and ignored — no stream state, no
/// decoder built that would throw on every frame. Garbage data after the ignored create must not
/// crash and must never surface as a frame.
@Test func unknownCodecStreamCreateIsIgnored() async throws {
    let p = StreamPlayer()
    let create = StreamCreate(surfaceID: 0, id: 7, flags: StreamFlags.topDown, codec: .vp8,
                               streamWidth: 64, streamHeight: 48, srcWidth: 64, srcHeight: 48,
                               dest: SpiceRect(top: 0, left: 0, bottom: 48, right: 64), clip: .none)
    await p.handle(create: create)
    await p.handle(data: StreamData(id: 7, mmTime: 0, data: [0xDE, 0xAD, 0xBE, 0xEF], sized: nil))
    await p.finish()
    var frames = 0
    for await e in p.events { if case .frame = e { frames += 1 } }
    #expect(frames == 0)
}

/// `flags & StreamFlags.topDown == 0` must flip rows before emit — checked with a two-tone frame
/// since a solid color can't distinguish row order.
@Test func bottomUpMJPEGFlipsRowsBeforeEmit() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate(flags: 0))
    let top = (r: UInt8(255), g: UInt8(0), b: UInt8(0))
    let bottom = (r: UInt8(0), g: UInt8(0), b: UInt8(255))
    await p.handle(data: StreamData(id: 1, mmTime: 0, data: try jpegFrame(width: 64, height: 48, top: top, bottom: bottom), sized: nil))
    await p.finish()
    var frames: [StreamFrame] = []
    for await e in p.events { if case let .frame(f) = e { frames.append(f) } }
    #expect(frames.count == 1)
    let f = frames[0]
    // Undoing the decoder's natural top-down output, row 2 (near the top of the *emitted* frame)
    // must now read as the JPEG's bottom color, and vice versa.
    let topRowOffset = (2 * f.width + 2) * 4
    let bottomRowOffset = ((f.height - 3) * f.width + 2) * 4
    #expect(abs(Int(f.pixels[topRowOffset + 2]) - Int(bottom.r)) < 16)
    #expect(abs(Int(f.pixels[bottomRowOffset + 2]) - Int(top.r)) < 16)
}
