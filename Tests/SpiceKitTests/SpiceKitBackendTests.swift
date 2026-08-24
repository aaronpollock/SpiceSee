import Testing
import SpiceCanvas
import SpiceWire
@testable import SpiceCore
@testable import SpiceKit

/// `SpiceKitBackend` itself lives in the app target, which SPM does not build. These pin the two
/// things it relies on: the shape of the pixels it forwards verbatim, and the error classification
/// that decides which failure sheet the user sees.

private func createSurface(id: UInt32, _ w: UInt32, _ h: UInt32, primary: Bool) -> DisplayMessage {
    var b = SpiceWriter(); b.u32(id); b.u32(w); b.u32(h); b.u32(32); b.u32(primary ? 1 : 0)
    return try! DisplayMessage(type: DisplayServerMsg.surfaceCreate.rawValue, payload: b.bytes)
}

private func fill(surface: UInt32, _ box: SpiceRect, color: UInt32) -> DisplayMessage {
    var w = SpiceWriter()
    w.u32(surface); w.i32(box.top); w.i32(box.left); w.i32(box.bottom); w.i32(box.right); w.u8(0)
    w.u8(1); w.u32(color); w.u16(ROPD.opPut)
    w.u8(0); w.i32(0); w.i32(0); w.u32(0)
    return try! DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes)
}

private func updates(from canvas: Canvas) async -> [SurfaceUpdate] {
    await canvas.finish()
    var out: [SurfaceUpdate] = []
    for await e in canvas.events { if case let .updated(u) = e { out.append(u) } }
    return out
}

@Test func surfaceUpdatesAreTightlyPackedBGRA() async throws {
    // FrameUpdate documents `width * 4` bytes per row, and the adapter forwards `pixels` verbatim
    // rather than restriding — so SurfaceUpdate has to satisfy that already.
    let canvas = Canvas()
    await canvas.apply(createSurface(id: 0, 8, 4, primary: true))
    await canvas.apply(fill(surface: 0, SpiceRect(top: 1, left: 2, bottom: 3, right: 5), color: 0x00FF00))
    let all = await updates(from: canvas)
    let u = try #require(all.last)
    #expect(Int(u.rect.width) == 3 && Int(u.rect.height) == 2)
    #expect(u.pixels.count == 3 * 2 * 4)
    #expect(u.surfaceWidth == 8 && u.surfaceHeight == 4)
    #expect(u.isPrimary)
    // Row 0 of the extracted rect is green, proving rows are packed at rect.width, not surface width.
    #expect(u.pixels[0] == 0x00 && u.pixels[1] == 0xFF && u.pixels[2] == 0x00)
}

@Test func secondarySurfacesAreNotPrimary() async throws {
    // Off-screen surfaces are scratch buffers for later composition; the adapter must not forward
    // them, or intermediate garbage lands in the viewport.
    let canvas = Canvas()
    await canvas.apply(createSurface(id: 1, 4, 4, primary: false))
    await canvas.apply(fill(surface: 1, SpiceRect(top: 0, left: 0, bottom: 4, right: 4), color: 0xFF0000))
    let all = await updates(from: canvas)
    #expect(!all.isEmpty)
    #expect(all.allSatisfy { !$0.isPrimary })
}

@Test func spiceErrorClassification() {
    // The design's failure copy is keyed to these categories, and the raw SPICE error never reaches
    // the sheet text — it goes to the log.
    #expect(ConnectFailureKind.of(SpiceError(.link(.permissionDenied))) == .passwordRejected)
    #expect(ConnectFailureKind.of(SpiceError(.auth)) == .passwordRejected)
    #expect(ConnectFailureKind.of(SpiceError(.connect)) == .refused)
    #expect(ConnectFailureKind.of(SpiceError(.tls)) == .hostSubjectMismatch)
    #expect(ConnectFailureKind.of(SpiceError(.closed)) == .other)
    #expect(ConnectFailureKind.of(SpiceError(.protocolError(.badOffset(3)))) == .other)
    #expect(ConnectFailureKind.of(SpiceError(.link(.channelNotAvailable))) == .other)
}
