import Testing
@testable import SpiceWire

/// Builds a migration body: six u32 header words, then the pointed-to strings.
private func body(port: UInt32, sport: UInt32, host: String?, subject: String?) -> [UInt8] {
    var w = SpiceWriter()
    let hostBytes: [UInt8] = host.map { Array($0.utf8) + [0] } ?? []
    let subjectBytes: [UInt8] = subject.map { Array($0.utf8) + [0] } ?? []
    let headerSize: UInt32 = 24
    w.u32(port); w.u32(sport)
    w.u32(UInt32(hostBytes.count)); w.u32(hostBytes.isEmpty ? 0 : headerSize)
    w.u32(UInt32(subjectBytes.count)); w.u32(subjectBytes.isEmpty ? 0 : headerSize + UInt32(hostBytes.count))
    w.bytes(hostBytes); w.bytes(subjectBytes)
    return w.bytes
}

@Test func parsesASwitchHostWithBothPorts() throws {
    let payload = body(port: 5900, sport: 5901, host: "pve3.lan", subject: "CN=pve3,O=PVE Cluster Manager CA")
    guard case let .migrateSwitchHost(t) = try MainMessage(type: MainServerMsg.migrateSwitchHost.rawValue, payload: payload) else {
        Issue.record("not a switch host"); return
    }
    #expect(t == MigrationTarget(host: "pve3.lan", port: 5900, tlsPort: 5901,
                                 certSubject: "CN=pve3,O=PVE Cluster Manager CA"))
}

@Test func absentPortsAndSubjectAreNil() throws {
    let payload = body(port: 0, sport: 0xFFFF_FFFF, host: "h", subject: nil)
    guard case let .migrateSwitchHost(t) = try MainMessage(type: MainServerMsg.migrateSwitchHost.rawValue, payload: payload) else {
        Issue.record("not a switch host"); return
    }
    #expect(t == MigrationTarget(host: "h", port: nil, tlsPort: nil, certSubject: nil))
}

@Test func migrateBeginUsesTheSameShape() throws {
    let payload = body(port: 1, sport: 0, host: "a", subject: nil)
    guard case let .migrateBegin(t) = try MainMessage(type: MainServerMsg.migrateBegin.rawValue, payload: payload) else {
        Issue.record("not a begin"); return
    }
    #expect(t.host == "a" && t.port == 1)
}

@Test func emptyMigrationMessagesParse() throws {
    #expect(try MainMessage(type: MainServerMsg.migrateCancel.rawValue, payload: []).isMigrateCancel)
    #expect(try MainMessage(type: MainServerMsg.migrateEnd.rawValue, payload: []).isMigrateEnd)
}

@Test func hostileMigrationBodiesThrowInsteadOfTrapping() {
    func expectThrow(_ payload: [UInt8], _ what: String) {
        #expect(throws: WireError.self, "\(what)") {
            try MainMessage(type: MainServerMsg.migrateSwitchHost.rawValue, payload: payload)
        }
    }
    expectThrow([], "empty body")
    expectThrow(Array(repeating: 0, count: 20), "truncated header")
    var offPast = SpiceWriter()
    offPast.u32(0); offPast.u32(0); offPast.u32(8); offPast.u32(9_999); offPast.u32(0); offPast.u32(0)
    expectThrow(offPast.bytes, "host offset past the end")
    var hugeSize = SpiceWriter()
    hugeSize.u32(0); hugeSize.u32(0); hugeSize.u32(1 << 20); hugeSize.u32(24); hugeSize.u32(0); hugeSize.u32(0)
    expectThrow(hugeSize.bytes, "host size beyond the cap")
    var unterminated = SpiceWriter()
    unterminated.u32(0); unterminated.u32(0); unterminated.u32(4); unterminated.u32(24); unterminated.u32(0); unterminated.u32(0)
    unterminated.bytes([0x61, 0x62, 0x63, 0x64])   // "abcd", no NUL
    expectThrow(unterminated.bytes, "host is not NUL-terminated")
    // A host with no bytes at all is not a target we can reconnect to.
    expectThrow(body(port: 1, sport: 0, host: nil, subject: nil), "no host")
}

private extension MainMessage {
    var isMigrateCancel: Bool { if case .migrateCancel = self { true } else { false } }
    var isMigrateEnd: Bool { if case .migrateEnd = self { true } else { false } }
}
