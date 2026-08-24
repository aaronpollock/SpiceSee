import Foundation
import Security

/// What a `.vv` file tells us to require of the server: its CA is the only anchor we accept, and the
/// peer's subject must equal `host-subject`. Deciding this here — not inside the `sec_protocol`
/// callback — is what makes it testable without a socket.
public struct TLSPolicy: Sendable {
    public let anchors: [SecCertificate]
    public let hostSubject: String?

    public init(caPEM: String?, hostSubject: String?) throws {
        anchors = try caPEM.map { try Certificates.parsePEM($0) } ?? []
        self.hostSubject = hostSubject
    }

    /// nil when the peer is acceptable. `peerChain` is leaf-first, as both SecTrust and
    /// `sec_trust_copy_ref` deliver it.
    public func verify(peerChain: [SecCertificate]) -> TLSFailure? {
        guard let leaf = peerChain.first else { return .badCertificate("server sent no certificate") }

        var trust: SecTrust?
        // A basic X.509 policy, not an SSL-hostname policy: Proxmox certificates are issued to the
        // node's cluster name, which need not match the address we dialled. `host-subject` is the
        // identity check, exactly as it is in spice-gtk.
        let status = SecTrustCreateWithCertificates(peerChain as CFArray, SecPolicyCreateBasicX509(), &trust)
        guard status == errSecSuccess, let trust else {
            return .badCertificate("could not evaluate the certificate chain (OSStatus \(status))")
        }
        if !anchors.isEmpty {
            guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
                return .badCertificate("could not pin the connection to the file's CA")
            }
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            let reason = (error as Error?)?.localizedDescription ?? "not trusted"
            return .untrusted(reason)
        }

        guard let hostSubject else { return nil }
        do {
            guard try Certificates.matches(hostSubject: hostSubject, certificate: leaf) else {
                let presented = (try? Certificates.subjectDN(of: leaf)) ?? "unreadable subject"
                return .subjectMismatch(expected: hostSubject, presented: presented)
            }
        } catch {
            return .badCertificate("could not read the server's subject")
        }
        return nil
    }
}
