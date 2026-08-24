import Foundation
import Security

/// Certificate handling for the `.vv` trust model: the file's `ca` is the *only* anchor, and the
/// peer's subject must equal the file's `host-subject`. Both come from an untrusted download, so
/// every step validates rather than assumes.
public enum Certificates {
    /// Longest PEM we will read — a chain of a few certificates is well under this.
    static let maxPEMBytes = 64 << 10

    public static func parsePEM(_ pem: String) throws -> [SecCertificate] {
        guard pem.utf8.count <= maxPEMBytes else { throw SpiceError(.tls(.badCertificate("CA is too large"))) }
        var certificates: [SecCertificate] = []
        var base64 = ""
        var inside = false
        for line in pem.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN CERTIFICATE") { inside = true; base64 = ""; continue }
            if trimmed.hasPrefix("-----END CERTIFICATE") {
                guard inside, let der = Data(base64Encoded: base64),
                      let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                    throw SpiceError(.tls(.badCertificate("CA is not a valid certificate")))
                }
                certificates.append(certificate)
                inside = false
                continue
            }
            if inside { base64 += trimmed }
        }
        guard !certificates.isEmpty else { throw SpiceError(.tls(.badCertificate("no certificate found"))) }
        return certificates
    }

    /// The subject's relative distinguished names, in the certificate's own (DER) order — which is
    /// the order Proxmox writes `host-subject` in.
    public static func subjectComponents(of certificate: SecCertificate) throws -> [(attribute: String, value: String)] {
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, &error) as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let entries = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            throw SpiceError(.tls(.badCertificate("certificate has no readable subject")))
        }
        // Fail closed: silently dropping an entry (e.g. a multi-valued RDN or an exotic attribute
        // delivered as data, not a String) would shrink the component count, and `matches` relies
        // on that count to reject anything but an exact, same-length subject.
        return try entries.map { entry in
            guard let oid = entry[kSecPropertyKeyLabel as String] as? String,
                  let value = entry[kSecPropertyKeyValue as String] as? String else {
                throw SpiceError(.tls(.badCertificate("certificate has an unreadable subject entry")))
            }
            return (shortName(forOID: oid), value)
        }
    }

    /// "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com"
    public static func subjectDN(of certificate: SecCertificate) throws -> String {
        try subjectComponents(of: certificate).map { "\($0.attribute)=\($0.value)" }.joined(separator: ",")
    }

    /// spice-gtk (`spice-common/common/ssl_verify.c`) compares the expected subject with the peer's
    /// entry by entry, in order — not as a substring and not order-insensitively. So do we.
    public static func matches(hostSubject: String, certificate: SecCertificate) throws -> Bool {
        let expected = parseSubject(hostSubject)
        guard !expected.isEmpty else { return false }
        let actual = try subjectComponents(of: certificate)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).allSatisfy {
            $0.attribute.caseInsensitiveCompare($1.attribute) == .orderedSame && $0.value == $1.value
        }
    }

    /// Splits "OU=a,O=b,CN=c" on commas, then on the FIRST '=' of each component, so a value may
    /// itself contain '='. Escaped commas (RFC 4514 `\,`) are not interpreted — a value containing
    /// one splits into a fragment with no '=', which safely fails to parse (and so fails to match)
    /// rather than being read as part of the value. Returns [] for anything that is not in that shape.
    public static func parseSubject(_ dn: String) -> [(attribute: String, value: String)] {
        var parts: [(String, String)] = []
        for component in dn.split(separator: ",", omittingEmptySubsequences: false) {
            let text = component.trimmingCharacters(in: .whitespaces)
            guard let eq = text.firstIndex(of: "=") else { return [] }
            let attribute = String(text[text.startIndex ..< eq]).trimmingCharacters(in: .whitespaces)
            let value = String(text[text.index(after: eq)...])
            guard !attribute.isEmpty else { return [] }
            parts.append((attribute, value))
        }
        return parts
    }

    private static func shortName(forOID oid: String) -> String {
        switch oid {
        case "2.5.4.3": "CN"
        case "2.5.4.6": "C"
        case "2.5.4.7": "L"
        case "2.5.4.8": "ST"
        case "2.5.4.9": "STREET"
        case "2.5.4.10": "O"
        case "2.5.4.11": "OU"
        case "2.5.4.5": "serialNumber"
        case "0.9.2342.19200300.100.1.25": "DC"
        case "1.2.840.113549.1.9.1": "emailAddress"
        default: oid
        }
    }
}
