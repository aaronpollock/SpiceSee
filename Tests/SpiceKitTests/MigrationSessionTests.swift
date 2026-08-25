import Foundation
import Testing
import SpiceWire
import SpiceCore
@testable import SpiceKit

@Test func switchHostBecomesAMigratedEvent() async throws {
    var switchBody = SpiceWriter()
    let host = Array("pve3.lan".utf8) + [0]
    switchBody.u32(5900); switchBody.u32(5901)
    switchBody.u32(UInt32(host.count)); switchBody.u32(24)
    switchBody.u32(0); switchBody.u32(0)
    switchBody.bytes(host)

    var mi = SpiceWriter(); [1, 1, 1, 1, 0, 10, 0, 0].forEach { mi.u32(UInt32($0)) }
    var cl = SpiceWriter(); cl.u32(0)
    let main = InMemoryTransport(input: try fakeLink(body:
        frame(MainServerMsg.`init`.rawValue, mi.bytes)
        + frame(MainServerMsg.channelsList.rawValue, cl.bytes)
        + frame(MainServerMsg.migrateSwitchHost.rawValue, switchBody.bytes)))

    let session = try await SpiceSession.connect(password: nil) { _ in main }
    var targets: [MigrationTarget] = []
    for await e in session.events {
        if case let .migrated(t) = e { targets.append(t) }
        if case .disconnected = e { break }
    }
    #expect(targets == [MigrationTarget(host: "pve3.lan", port: 5900, tlsPort: 5901, certSubject: nil)])
}

@Test func anUnparseableMigrationMessageDoesNotEndTheSession() async throws {
    var mi = SpiceWriter(); [1, 1, 1, 1, 0, 10, 0, 0].forEach { mi.u32(UInt32($0)) }
    var cl = SpiceWriter(); cl.u32(0)
    var mm = SpiceWriter(); mm.u32(777)
    let main = InMemoryTransport(input: try fakeLink(body:
        frame(MainServerMsg.`init`.rawValue, mi.bytes)
        + frame(MainServerMsg.channelsList.rawValue, cl.bytes)
        + frame(MainServerMsg.migrateSwitchHost.rawValue, [0, 0, 0])      // truncated: dropped
        + frame(MainServerMsg.multiMediaTime.rawValue, mm.bytes)))        // still delivered after it

    let session = try await SpiceSession.connect(password: nil) { _ in main }
    var migrated = 0, disconnected = false
    for await e in session.events {
        if case .migrated = e { migrated += 1 }
        if case .disconnected = e { disconnected = true; break }
    }
    #expect(migrated == 0 && disconnected)
}
