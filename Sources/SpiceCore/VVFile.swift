import Foundation

/// The `proxy=` endpoint of a `.vv`. Proxmox routes every console through pveproxy's HTTP
/// CONNECT proxy: the file's `host` is then an opaque routing token only the proxy understands,
/// so a file whose proxy we cannot speak must fail to parse rather than be dialled directly.
public struct HTTPConnectProxy: Sendable, Equatable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) { self.host = host; self.port = port }

    /// Accepts `http://host[:port][/]` and scheme-less `host[:port]`; the port defaults to
    /// pveproxy's 3128. Any other scheme throws.
    public init(parsing value: String) throws {
        var rest = value
        if let scheme = rest.range(of: "://") {
            guard rest[..<scheme.lowerBound].lowercased() == "http" else {
                throw SpiceError(.vvFile("unsupported proxy '\(value)': only http is supported"))
            }
            rest = String(rest[scheme.upperBound...])
        }
        if rest.hasSuffix("/") { rest.removeLast() }
        var port: UInt16 = 3128
        if let colon = rest.lastIndex(of: ":") {
            guard let parsed = UInt16(rest[rest.index(after: colon)...]), parsed != 0 else {
                throw SpiceError(.vvFile("bad proxy port in '\(value)'"))
            }
            port = parsed
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty else { throw SpiceError(.vvFile("no proxy host in '\(value)'")) }
        self.init(host: rest, port: port)
    }
}

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
    public var proxy: HTTPConnectProxy?

    public init(host: String, port: UInt16?, tlsPort: UInt16?, password: String?,
                hostSubject: String?, caPEM: String?, title: String?, deleteAfterConnecting: Bool,
                proxy: HTTPConnectProxy? = nil) {
        self.host = host; self.port = port; self.tlsPort = tlsPort; self.password = password
        self.hostSubject = hostSubject; self.caPEM = caPEM; self.title = title
        self.deleteAfterConnecting = deleteAfterConnecting; self.proxy = proxy
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
                      deleteAfterConnecting: fields["delete-this-file"] == "1",
                      proxy: try fields["proxy"].flatMap { $0.isEmpty ? nil : try HTTPConnectProxy(parsing: $0) })
    }

    /// `.vv` escapes the CA's newlines as the two characters `\` `n`.
    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n")
    }
}
