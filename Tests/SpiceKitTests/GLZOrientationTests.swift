import Foundation
import Testing
import SpiceWire
import SpiceCanvas
@testable import SpiceCore

/// A Windows guest sends most incremental draws as GLZ, and marks many of them bottom-up. The GLZ
/// header's `top_down` bit was parsed by the vendored decoder but never surfaced through the bridge,
/// so those images rendered vertically mirrored — desktop icons and label text upside down while the
/// initial full-screen repaint looked fine. Recorded from the live guest; replays headless.
@Test func glzBottomUpImagesRenderUpright() async throws {
    let url = try #require(Bundle.module.url(forResource: "win-glz-bottomup.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let bytes = [UInt8](try Data(contentsOf: url))
    let t = InMemoryTransport(input: bytes)
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    for await m in channel.messages { await canvas.apply(m) }
    let id = try #require(await canvas.primarySurfaceID)
    let frame = try #require(await canvas.snapshot(surfaceID: id))

    let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/win-glz-bottomup.golden.png")
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
