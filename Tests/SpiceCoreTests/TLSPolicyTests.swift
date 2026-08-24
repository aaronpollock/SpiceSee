import Foundation
import Security
import Testing
@testable import SpiceCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func certificates(_ name: String) throws -> [SecCertificate] {
    try Certificates.parsePEM(try fixture(name))
}

private let proxmoxSubject = "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com"

@Test func trustsAChainSignedByTheFileSCA() throws {
    let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: proxmoxSubject)
    #expect(policy.verify(peerChain: try certificates("test-server.pem")) == nil)
}

@Test func rejectsAMismatchedSubjectWithBothNames() throws {
    let expectedSubject = "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve3.example.com"
    let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: expectedSubject)
    guard case let .subjectMismatch(expected, presented)? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected a subject mismatch"); return
    }
    #expect(expected == expectedSubject)
    #expect(presented == proxmoxSubject)
}

@Test func rejectsAChainTheCADidNotSign() throws {
    // The "other" CA signed nothing in this chain, so evaluation must fail before the subject check.
    let policy = try TLSPolicy(caPEM: try fixture("other-ca.pem"), hostSubject: proxmoxSubject)
    guard case .untrusted? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected untrusted"); return
    }
}

@Test func rejectsAnEmptyChain() throws {
    let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: nil)
    guard case .badCertificate? = policy.verify(peerChain: []) else { Issue.record("expected badCertificate"); return }
}

@Test func withoutACAThePolicyStillPinsTheSubject() throws {
    // No `ca` in the .vv: fall back to the system trust store, but keep the subject pin.
    let policy = try TLSPolicy(caPEM: nil, hostSubject: proxmoxSubject)
    #expect(policy.anchors.isEmpty)
    // A self-signed cert is not in the system store, so this must be untrusted, not a subject error.
    guard case .untrusted? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected untrusted"); return
    }
}

@Test func aBadCAInTheFileIsRejectedAtConstruction() {
    #expect(throws: SpiceError.self) { try TLSPolicy(caPEM: "not a certificate", hostSubject: nil) }
}
