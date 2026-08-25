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
    let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: proxmoxSubject, host: "pve1.example.com")
    #expect(policy.verify(peerChain: try certificates("test-server.pem")) == nil)
}

@Test func rejectsAMismatchedSubjectWithBothNames() throws {
    let expectedSubject = "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve3.example.com"
    let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: expectedSubject, host: "pve1.example.com")
    guard case let .subjectMismatch(expected, presented)? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected a subject mismatch"); return
    }
    #expect(expected == expectedSubject)
    #expect(presented == proxmoxSubject)
}

@Test func rejectsAChainTheCADidNotSign() throws {
    // The "other" CA signed nothing in this chain, so evaluation must fail before the subject check.
    let policy = try TLSPolicy(caPEM: try fixture("other-ca.pem"), hostSubject: proxmoxSubject, host: "pve1.example.com")
    guard case .untrusted? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected untrusted"); return
    }
}

@Test func rejectsAnEmptyChain() throws {
    let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: nil, host: "pve1.example.com")
    guard case .badCertificate? = policy.verify(peerChain: []) else { Issue.record("expected badCertificate"); return }
}

@Test func withoutACAThePolicyStillPinsTheSubject() throws {
    // No `ca` in the .vv: fall back to the system trust store, but keep the subject pin.
    let policy = try TLSPolicy(caPEM: nil, hostSubject: proxmoxSubject, host: "pve1.example.com")
    #expect(policy.anchors.isEmpty)
    // A self-signed cert is not in the system store, so this must be untrusted, not a subject error.
    guard case .untrusted? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected untrusted"); return
    }
}

@Test func acceptsTheDialledHostWhenTheCertificateNamesIt() throws {
    // The positive half of the hostname path — plain QEMU/libvirt over TLS with no `host-subject`.
    // `test-server-san.pem` is the same CA's certificate for `spice.test`. Apple's TLS rules bind it
    // to 397 days, so it expires around 2027-09-26; `scripts/dev-tls.sh` re-mints it.
    let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: nil, host: "spice.test")
    #expect(policy.verify(peerChain: try certificates("test-server-san.pem")) == nil)
}

@Test func rejectsACertificateIssuedToAnotherHost() throws {
    let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: nil, host: "wrong.test")
    guard case .untrusted? = policy.verify(peerChain: try certificates("test-server-san.pem")) else {
        Issue.record("expected untrusted"); return
    }
}

@Test func withoutASubjectTheNameIsEvaluatedNotWaivedThrough() throws {
    // The widening case: a pinned CA and no `host-subject` used to accept anything that CA had
    // signed, whatever name it carried. Now an SSL policy for the dialled host evaluates the name.
    // The fixture carries CN=pve1.example.com and no SAN, which SecPolicyCreateSSL rejects outright
    // ("certificate is not standards compliant"), so this pins "the name is evaluated" — the fixture
    // cannot separate a wrong host from a SAN-less certificate, and cannot show a right host passing.
    for host in ["pve1.example.com", "evil.example.com"] {
        let policy = try TLSPolicy(caPEM: try fixture("test-ca.pem"), hostSubject: nil, host: host)
        guard case .untrusted? = policy.verify(peerChain: try certificates("test-server.pem")) else {
            Issue.record("expected untrusted for host \(host)"); return
        }
    }
}

@Test func withNeitherACANorASubjectTheSystemStoreAloneIsNotEnough() throws {
    // Neither anchor nor subject pinned: system anchors *and* the hostname, never system anchors alone.
    let policy = try TLSPolicy(caPEM: nil, hostSubject: nil, host: "evil.example.com")
    #expect(policy.anchors.isEmpty)
    guard case .untrusted? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected untrusted"); return
    }
}

@Test func aBadCAInTheFileIsRejectedAtConstruction() {
    #expect(throws: SpiceError.self) { try TLSPolicy(caPEM: "not a certificate", hostSubject: nil, host: "pve1.example.com") }
}
