import Foundation
import Testing
@testable import SpiceCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func parsesAProxmoxFile() throws {
    let vv = try VVFile.parse(try fixture("proxmox.vv"))
    #expect(vv.host == "192.168.1.10")
    #expect(vv.port == nil)                    // port=0 means "no plain port"
    #expect(vv.tlsPort == 61000)
    #expect(vv.password == "Zm9vYmFyLXRpY2tldA==")
    #expect(vv.hostSubject == "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com")
    #expect(vv.deleteAfterConnecting)
    #expect(vv.title == "VM 100 - win11 (Press %s to release the cursor)")
    let ca = try #require(vv.caPEM)
    #expect(ca.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
    #expect(ca.hasSuffix("-----END CERTIFICATE-----\n"))
    #expect(!ca.contains("\\n"))                // the two-character escape is gone
}

@Test func parsesAPlainFile() throws {
    let vv = try VVFile.parse(try fixture("plain.vv"))
    #expect(vv == VVFile(host: "10.0.0.4", port: 5900, tlsPort: nil, password: nil,
                         hostSubject: nil, caPEM: nil, title: nil, deleteAfterConnecting: false))
}

@Test func keysAreCaseInsensitiveAndValuesKeepTheirEquals() throws {
    let vv = try VVFile.parse("""
    [virt-viewer]
    TYPE=spice
    Host=example.com
    TLS-Port=5901
    Host-Subject=CN=a=b,O=x
    """)
    #expect(vv.host == "example.com" && vv.tlsPort == 5901)
    #expect(vv.hostSubject == "CN=a=b,O=x")     // only the FIRST '=' separates key from value
}

@Test func ignoresCommentsBlankLinesAndUnknownKeys() throws {
    let vv = try VVFile.parse("""
    # a comment
    ; another

    [virt-viewer]
    host=h
    port=1
    proxy=http://p:3128
    versions=x
    """)
    #expect(vv.host == "h" && vv.port == 1)
}

@Test func rejectsFilesWeCannotConnectWith() {
    #expect(throws: SpiceError.self) { try VVFile.parse("[virt-viewer]\nport=5900") }          // no host
    #expect(throws: SpiceError.self) { try VVFile.parse("[virt-viewer]\nhost=h") }             // no usable port
    #expect(throws: SpiceError.self) { try VVFile.parse("host=h\nport=1") }                    // no section
    #expect(throws: SpiceError.self) { try VVFile.parse("[virt-viewer]\nhost=h\nport=99999") } // not a UInt16
    #expect(throws: SpiceError.self) { try VVFile.parse("[virt-viewer]\ntype=vnc\nhost=h\nport=1") }
}

@Test func toleratesHostileInput() throws {
    // A 4 MB value must not be kept, and a truncated CA must not be handed on as if it were a cert.
    let huge = "[virt-viewer]\nhost=h\nport=1\ntitle=" + String(repeating: "x", count: 4 << 20)
    #expect(throws: SpiceError.self) { try VVFile.parse(huge) }
    let badCA = try VVFile.parse("[virt-viewer]\nhost=h\nport=1\nca=not a certificate")
    #expect(badCA.caPEM == "not a certificate")   // parsing defers validation to Certificates
    #expect(throws: SpiceError.self) { try VVFile.parse("[virt-viewer]\nhost=\nport=1") }
}

@Test func parseFromDiskRejectsOversizedAndNonUTF8Files() throws {
    let dir = FileManager.default.temporaryDirectory
    let oversized = dir.appendingPathComponent(UUID().uuidString + ".vv")
    try Data(repeating: 0x41, count: VVFile.maxFileBytes + 1).write(to: oversized)
    defer { try? FileManager.default.removeItem(at: oversized) }
    #expect(throws: SpiceError.self) { try VVFile.parse(contentsOf: oversized) }

    let notUTF8 = dir.appendingPathComponent(UUID().uuidString + ".vv")
    try Data([0xFF, 0xFE, 0xFF]).write(to: notUTF8)
    defer { try? FileManager.default.removeItem(at: notUTF8) }
    #expect(throws: SpiceError.self) { try VVFile.parse(contentsOf: notUTF8) }

    let text = try fixture("plain.vv")
    let valid = dir.appendingPathComponent(UUID().uuidString + ".vv")
    try text.write(to: valid, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: valid) }
    #expect(try VVFile.parse(contentsOf: valid) == VVFile.parse(text))
}
