import Foundation
import Security
import Testing
@testable import SpiceCore

private func pem(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private let proxmoxSubject = "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com"

@Test func parsesPEMIntoCertificates() throws {
    let certs = try Certificates.parsePEM(try pem("test-ca.pem"))
    #expect(certs.count == 1)
    // Two concatenated certificates parse as two, which is how a chain arrives in a .vv.
    let chain = try Certificates.parsePEM(pem("test-ca.pem") + pem("test-server.pem"))
    #expect(chain.count == 2)
}

@Test func rejectsGarbagePEM() {
    #expect(throws: SpiceError.self) { try Certificates.parsePEM("not a certificate") }
    #expect(throws: SpiceError.self) { try Certificates.parsePEM("") }
    // Well-formed armour, payload that is not DER.
    #expect(throws: SpiceError.self) {
        try Certificates.parsePEM("-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n")
    }
}

@Test func readsTheSubjectInDEROrder() throws {
    let server = try #require(try Certificates.parsePEM(try pem("test-server.pem")).first)
    let parts = try Certificates.subjectComponents(of: server)
    #expect(parts.map(\.attribute) == ["OU", "O", "CN"])
    #expect(parts.map(\.value) == ["PVE Cluster Node", "Proxmox Virtual Environment", "pve1.example.com"])
    #expect(try Certificates.subjectDN(of: server) == proxmoxSubject)
}

@Test func matchesTheProxmoxHostSubject() throws {
    let server = try #require(try Certificates.parsePEM(try pem("test-server.pem")).first)
    #expect(try Certificates.matches(hostSubject: proxmoxSubject, certificate: server))
    // Whitespace around separators is tolerated; the values are not altered.
    #expect(try Certificates.matches(hostSubject: "OU=PVE Cluster Node, O=Proxmox Virtual Environment, CN=pve1.example.com",
                                     certificate: server))
    // Attribute names are case-insensitive, values are not.
    #expect(try Certificates.matches(hostSubject: "ou=PVE Cluster Node,o=Proxmox Virtual Environment,cn=pve1.example.com",
                                     certificate: server))
}

@Test func rejectsAnythingButAnExactSubject() throws {
    let server = try #require(try Certificates.parsePEM(try pem("test-server.pem")).first)
    // Different host — the case this whole feature exists to catch.
    #expect(!(try Certificates.matches(hostSubject: "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve3.example.com",
                                       certificate: server)))
    // A prefix is not a match: spice-gtk compares the whole name, entry by entry.
    #expect(!(try Certificates.matches(hostSubject: "CN=pve1.example.com", certificate: server)))
    // Right components, wrong order.
    #expect(!(try Certificates.matches(hostSubject: "CN=pve1.example.com,O=Proxmox Virtual Environment,OU=PVE Cluster Node",
                                       certificate: server)))
    // Extra component.
    #expect(!(try Certificates.matches(hostSubject: proxmoxSubject + ",C=DE", certificate: server)))
    #expect(!(try Certificates.matches(hostSubject: "", certificate: server)))
    #expect(!(try Certificates.matches(hostSubject: "garbage", certificate: server)))
}

@Test func parsesSubjectStringsWithEmbeddedEquals() {
    let parts = Certificates.parseSubject("CN=a=b,O=x")
    #expect(parts.map(\.attribute) == ["CN", "O"])
    #expect(parts.map(\.value) == ["a=b", "x"])
}
