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
