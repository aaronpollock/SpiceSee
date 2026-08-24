import Foundation
import Testing
import SpiceWire
import SpiceCore
@testable import SpiceKit

@Test func sessionBringsUpMainAndDisplayFromRecordings() async throws {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))))
    }
    let main = try fixture("win-main.s2c"), display = try fixture("win-display.s2c")
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return InMemoryTransport(input: main)
        case .display: return InMemoryTransport(input: display)
        default: throw SpiceError(.unsupported("not in M1"), channel: desc)
        }
    }
    #expect(session.info.channels.contains(ChannelDescriptor(type: .display, id: 0)))
    var sawSurface = false
    for await e in session.events {
        if case .canvas(.surfaceCreated(let d)) = e, d.isPrimary { sawSurface = true }
        if case .disconnected = e { break }
    }
    #expect(sawSurface)
    let frame = try #require(await session.snapshotPrimary())
    #expect(frame.width > 0)
}
