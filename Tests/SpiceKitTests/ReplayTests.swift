import Foundation
import Testing
import SpiceWire
import SpiceCanvas
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

/// Replays the installed Windows 11 desktop recording (context menu, start menu, window drag).
/// It renders with ZERO unsupported commands — not because the canvas is complete, but because
/// this guest's QXL **WDDM** driver composites in the guest and pushes whole dirty-rect bitmaps:
/// the whole 7.8 MB capture is 126 `DRAW_COPY` and nothing else. So this is a tier-1 regression
/// canary over real traffic, and it proves nothing about tiers 2-3. See docs/dev-server.md,
/// "## Where tier-2/3 draw commands actually come from".
@Test func winDesktopReplayCompletes() async throws {
    let url = try #require(Bundle.module.url(forResource: "win-desktop.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let t = InMemoryTransport(input: [UInt8](try Data(contentsOf: url)))
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    let collector = Task {
        var tally: [String: Int] = [:]
        for await e in canvas.events { if case let .unsupported(what) = e { tally[what, default: 0] += 1 } }
        return tally
    }
    for await m in channel.messages { await canvas.apply(m) }
    await canvas.finish()
    let tally = await collector.value
    for (what, n) in tally.sorted(by: { $0.value > $1.value }) { print("unsupported ×\(n): \(what)") }
    let id = try #require(await canvas.primarySurfaceID)
    #expect(await canvas.snapshot(surfaceID: id) != nil)
}
