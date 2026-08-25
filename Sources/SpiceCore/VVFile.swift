import Foundation

/// A parsed `.vv` (virt-viewer) connection file — how Proxmox hands a console to a client.
///
/// The file is untrusted input from a download folder: every field is validated here, and nothing
/// is allocated from an attacker-controlled length. Certificate *content* is not validated at this
/// layer — `Certificates.parsePEM` owns that, so a bad `ca` fails at connect time with a TLS error
/// rather than making the whole file unreadable.
public struct VVFile: Sendable, Equatable {
    public var host: String
    /// `port=0` in the file means "no plain port"; it is `nil` here.
    public var port: UInt16?
    public var tlsPort: UInt16?
    public var password: String?
    public var hostSubject: String?
    public var caPEM: String?
    public var title: String?
    public var deleteAfterConnecting: Bool

    public init(host: String, port: UInt16?, tlsPort: UInt16?, password: String?,
                hostSubject: String?, caPEM: String?, title: String?, deleteAfterConnecting: Bool) {
        self.host = host; self.port = port; self.tlsPort = tlsPort; self.password = password
        self.hostSubject = hostSubject; self.caPEM = caPEM; self.title = title
        self.deleteAfterConnecting = deleteAfterConnecting
    }

    /// Longest value we will keep. Real files are a few KB; the CA is the only large field.
    static let maxValueBytes = 64 << 10
    static let maxFileBytes = 256 << 10

    public static func parse(contentsOf url: URL) throws -> VVFile {
        // One bounded read, never a stat followed by an unbounded one: a file can grow between the two.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        guard data.count <= maxFileBytes else { throw SpiceError(.vvFile("file is larger than 256 KB")) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SpiceError(.vvFile("file is not UTF-8"))
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> VVFile {
        var fields: [String: String] = [:]
        var inSection = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                inSection = line.lowercased() == "[virt-viewer]"
                continue
            }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: eq)...])
            guard value.utf8.count <= maxValueBytes else {
                throw SpiceError(.vvFile("value for '\(key)' is too long"))
            }
            fields[key] = value
        }
        guard !fields.isEmpty else { throw SpiceError(.vvFile("no [virt-viewer] section")) }

        if let type = fields["type"], type.lowercased() != "spice" {
            throw SpiceError(.vvFile("not a SPICE connection file (type=\(type))"))
        }
        guard let host = fields["host"], !host.isEmpty else { throw SpiceError(.vvFile("no host")) }

        func port(_ key: String) throws -> UInt16? {
            guard let raw = fields[key], !raw.isEmpty else { return nil }
            guard let value = UInt16(raw) else { throw SpiceError(.vvFile("bad \(key): \(raw)")) }
            return value == 0 ? nil : value
        }
        let plain = try port("port"), tls = try port("tls-port")
        guard plain != nil || tls != nil else { throw SpiceError(.vvFile("no usable port")) }

        return VVFile(host: host, port: plain, tlsPort: tls,
                      password: fields["password"].flatMap { $0.isEmpty ? nil : $0 },
                      hostSubject: fields["host-subject"].flatMap { $0.isEmpty ? nil : $0 },
                      caPEM: fields["ca"].flatMap { $0.isEmpty ? nil : unescape($0) },
                      title: fields["title"].flatMap { $0.isEmpty ? nil : $0 },
                      deleteAfterConnecting: fields["delete-this-file"] == "1")
    }

    /// `.vv` escapes the CA's newlines as the two characters `\` `n`.
    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n")
    }
}
