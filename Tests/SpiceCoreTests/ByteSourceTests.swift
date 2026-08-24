import Testing
@testable import SpiceCore

@Test func inMemoryReadsExactly() async throws {
    let t = InMemoryTransport(input: [1, 2, 3, 4, 5])
    #expect(try await t.read(exactly: 2) == [1, 2])
    #expect(try await t.read(exactly: 3) == [3, 4, 5])
}

@Test func inMemoryEOFThrowsClosed() async {
    let t = InMemoryTransport(input: [1])
    await #expect(throws: SpiceError.self) { _ = try await t.read(exactly: 2) }
}

@Test func inMemoryRecordsWrites() async throws {
    let t = InMemoryTransport(input: [])
    await t.write([9, 9]); await t.write([8])
    #expect(await t.written == [9, 9, 8])
}

@Test func nwConnectRefusedThrowsConnect() async {
    await #expect(throws: SpiceError.self) { _ = try await NWTransport.connect(host: "127.0.0.1", port: 1) }
}
