import Foundation
import Testing
import SpiceWire
import SpiceCanvas
import SpiceMedia
@testable import SpiceCore

/// Replays the display channel recorded from the Windows-installer guest (task 12) through the whole
/// stack headless and compares the rendered surface with a reviewed golden PNG.
@Test func winDisplayReplayMatchesGolden() async throws {
    let url = try #require(Bundle.module.url(forResource: "win-display.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let bytes = [UInt8](try Data(contentsOf: url))
    let t = InMemoryTransport(input: bytes)
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    for await m in channel.messages { await canvas.apply(m) }
    let id = try #require(await canvas.primarySurfaceID)
    let frame = try #require(await canvas.snapshot(surfaceID: id))

    let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/win-display.golden.png")
    if !FileManager.default.fileExists(atPath: goldenURL.path) {
        try PNG.encode(frame).write(to: goldenURL)
        Issue.record("golden written to \(goldenURL.path) — review it visually, then re-run")
        return
    }
    let golden = try PNG.decode(try Data(contentsOf: goldenURL))
    #expect(golden.width == frame.width && golden.height == frame.height)
    var mismatches = 0
    for y in 0 ..< frame.height { for x in 0 ..< frame.width where frame.pixel(x: x, y: y) & 0xFFFFFF != golden.pixel(x: x, y: y) & 0xFFFFFF { mismatches += 1 } }
    #expect(mismatches == 0, "\(mismatches) pixels differ")
}

/// Replays the installed Windows 11 desktop recording (context menu, start menu, window drag)
/// and checks it renders with ZERO unsupported commands and matches a visually reviewed golden.
/// This is **not** M4's draw-correctness gate for tiers 2-3 — it is a tier-1 regression canary
/// over real traffic. This guest's QXL **WDDM** driver composites in the guest and pushes whole
/// dirty-rect bitmaps: the whole 7.8 MB capture is 126 `DRAW_COPY` and nothing else, so
/// zero-unsupported was already true before any tier-2/3 code existed. Tiers 2-3 are proven by
/// the unit tests in Tasks 4-7. See docs/dev-server.md, "## Where tier-2/3 draw commands
/// actually come from".
@Test func winDesktopReplayMatchesGolden() async throws {
    let url = try #require(Bundle.module.url(forResource: "win-desktop.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let t = InMemoryTransport(input: [UInt8](try Data(contentsOf: url)))
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    let collector = Task {
        var unsupported: [String] = []
        for await e in canvas.events { if case let .unsupported(what) = e { unsupported.append(what) } }
        return unsupported
    }
    for await m in channel.messages { await canvas.apply(m) }
    await canvas.finish()
    #expect(await collector.value == [])
    let id = try #require(await canvas.primarySurfaceID)
    let frame = try #require(await canvas.snapshot(surfaceID: id))
    let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/win-desktop.golden.png")
    if !FileManager.default.fileExists(atPath: goldenURL.path) {
        try PNG.encode(frame).write(to: goldenURL)
        Issue.record("golden written to \(goldenURL.path) — review it visually, then re-run")
        return
    }
    let golden = try PNG.decode(try Data(contentsOf: goldenURL))
    expectClose(frame, golden, maxChannelDelta: 0, maxMismatchFraction: 0)
}

/// Tolerant image compare for pipelines that are not bit-exact across OS releases (JPEG, H.264).
/// maxChannelDelta 0 + fraction 0 degrades to the exact compare the lossless goldens use.
func expectClose(_ got: DecodedImage, _ want: DecodedImage, maxChannelDelta: Int, maxMismatchFraction: Double,
                 sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(got.width == want.width && got.height == want.height, sourceLocation: sourceLocation)
    guard got.width == want.width, got.height == want.height else { return }
    var mismatches = 0
    for i in stride(from: 0, to: got.pixels.count, by: 4) {
        for c in 0 ..< 3 where abs(Int(got.pixels[i + c]) - Int(want.pixels[i + c])) > maxChannelDelta {
            mismatches += 1; break
        }
    }
    let fraction = Double(mismatches) / Double(got.width * got.height)
    #expect(fraction <= maxMismatchFraction, "\(mismatches) pixels differ (\(fraction))", sourceLocation: sourceLocation)
}

/// Replays a real spice-server MJPEG streaming session (Linux Mint guest, `streaming-video=all`,
/// a terminal scrolling `find /`). This is the first real-traffic confirmation of the stream wire
/// layouts, which are otherwise transcribed from `spice.proto`: STREAM_CREATE/DATA must parse out
/// of a live capture and decode into frames of the advertised size. Stream messages route to the
/// player and draws to the canvas exactly as `SpiceSession` splits them; no `setMMTime` is called,
/// so nothing drops and the replay is deterministic (the player treats an unknown clock as on
/// time). The golden compares with tolerance — JPEG decode is not bit-exact across OS releases.
@Test func mintVideoReplayDecodesStreams() async throws {
    let url = try #require(Bundle.module.url(forResource: "mint-video.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let t = InMemoryTransport(input: [UInt8](try Data(contentsOf: url)))
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    let player = StreamPlayer()
    let unsupportedCollector = Task {
        var unsupported: [String] = []
        for await e in canvas.events { if case let .unsupported(what) = e { unsupported.append(what) } }
        return unsupported
    }
    let frameCollector = Task {
        var frames: [SpiceMedia.StreamFrame] = []
        var reports = 0
        for await e in player.events {
            switch e {
            case let .frame(f): frames.append(f)
            case .report: reports += 1
            case .destroyed, .allDestroyed: break
            }
        }
        return (frames, reports)
    }
    var creates = 0, datas = 0
    for await m in channel.messages {
        switch m {
        case let .streamCreate(c): creates += 1; await player.handle(create: c)
        case let .streamData(d): datas += 1; await player.handle(data: d)
        case let .streamClip(id, clip): await player.handle(clipChange: id, clip: clip)
        case let .streamDestroy(id): await player.handle(destroy: id)
        case .streamDestroyAll: await player.handleDestroyAll()
        case let .streamActivateReport(a): await player.handle(activateReport: a)
        default: await canvas.apply(m)
        }
    }
    await canvas.finish()
    await player.finish()
    let unsupported = await unsupportedCollector.value
    let (frames, _) = await frameCollector.value
    print("mint-video: \(creates) STREAM_CREATE, \(datas) STREAM_DATA, \(frames.count) decoded frames")
    #expect(creates > 0, "the recording was made with streaming-video=all; no STREAM_CREATE means the flag did not take")
    #expect(!frames.isEmpty, "streams present but none decoded")
    #expect(unsupported == [])

    let big = try #require(frames.max { $0.width * $0.height < $1.width * $1.height })
    let img = DecodedImage(width: big.width, height: big.height, pixels: big.pixels, hasAlpha: false)
    let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/mint-video-frame.golden.png")
    if !FileManager.default.fileExists(atPath: goldenURL.path) {
        try PNG.encode(img).write(to: goldenURL)
        Issue.record("golden written to \(goldenURL.path) — review it visually, then re-run")
        return
    }
    let golden = try PNG.decode(try Data(contentsOf: goldenURL))
    expectClose(img, golden, maxChannelDelta: 4, maxMismatchFraction: 0.002)
}
