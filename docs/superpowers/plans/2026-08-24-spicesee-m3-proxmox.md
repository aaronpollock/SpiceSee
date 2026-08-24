# SpiceSee M3 (Proxmox) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-click a Proxmox `.vv` file and get a console: `.vv` parsing, TLS with the file's embedded CA and pinned `host-subject`, and the migration reconnect prompt driven by real `MAIN_MIGRATE_SWITCH_HOST` messages.

**Architecture:** `.vv` parsing and certificate handling are pure value types in `SpiceCore` (`VVFile`, `Certificates`), so both are testable headless. TLS is `NWConnection` with `sec_protocol_options_set_verify_block`: the chain is evaluated against the `.vv`'s CA as the only anchor, then the leaf's subject DN is compared component-by-component with `host-subject`. `SpiceError.tls` grows structure so the failure sheet can show *expected* and *presented* subjects — the design requires both. The app gains a document-open path that connects immediately; no view changes.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, Network.framework (`NWProtocolTLS`, `sec_protocol_options_set_verify_block`), Security.framework (`SecCertificate`, `SecTrust`, `SecPolicy`, `SecCertificateCopyValues`), `openssl` + `socat` on the dev box for a real TLS endpoint.

**Spec:** `docs/superpowers/specs/2026-08-22-spicesee-design.md` — this plan implements §3's TLS, `.vv` and migration paragraphs and milestone M3. Previous plans: `2026-08-22-spicesee-m0-m1-pixels.md`, `2026-08-24-spicesee-m2-input.md` (both shipped; read their Global Constraints — the rules still bind).

## Global Constraints

- Swift 6 language mode, strict concurrency. No locks, no `@unchecked Sendable`, no `nonisolated(unsafe)` outside the one pre-existing use in `NWTransport.connect`.
- `platforms: [.macOS(.v14)]`. Universal binary. **No OpenSSL in the product** — Security.framework and Network.framework only. `openssl` appears solely as a *test* tool on the dev box, the same role it plays in `TicketOpenSSLTests`.
- `.vv` files and certificates are untrusted input: every parser accessor throws, no `!`, no unchecked subscripts, no unbounded allocation from a length field. A malformed `.vv` produces a caught error, never a trap.
- Dependency rule strictly downward: `SpiceWire` ← `SpiceCore` ← `SpiceKit` ← app. `SpiceCanvas` imports nothing from `SpiceCore`. Views never see SPICE types; `SpiceKitBackend` stays the only app file importing engine modules (plus `ViewportTransform`/`WheelAccumulator` geometry in the two input/present views).
- **No view changes.** `Models.swift` and `ConnectionStore.swift` are model/storage, not views — extending them is allowed. If a `View` needs editing, the seam is wrong: fix the adapter.
- The raw `SpiceError` never reaches sheet text. `ConnectFailureKind` decides the category in `SpiceKit` (tested); the wording stays in the app. The one exception the design *requires*: the host-subject sheet shows the expected and presented subject strings, which are certificate facts, not SPICE error codes.
- Existing failure copy is fixed by the design (`docs/design/design-text.txt` lines 110–130) — do not reword it.
- Tests use Swift Testing. Fixtures under `Tests/<Target>Tests/Fixtures/`. Commit after every task, conventional-commit prefixes.
- Library code logs via `os.Logger(subsystem: "com.spicesee", category:)`; no `print` outside executables. **A password or ticket must never be logged**, and neither must a CA's private key material.
- Input ordering rules from M2 stand: `SpiceSession.send` and `SessionBackend.sendInput` are synchronous and ordered; never wrap an input event in its own `Task`.
- Verification habit (memory `spicesee-verification-habits`): an encoder tested only against our own decoder proves nothing. Task 5 stands up a real OpenSSL TLS endpoint in front of the real SPICE server and proves the verify block against it — positive *and* both negative cases.

## What cannot be verified in this milestone

There is no Proxmox cluster available. Two things therefore ship untested against the real thing and must be listed as such in `docs/dev-server.md` and in the final report:

1. **A genuine Proxmox `.vv` file.** Task 1's fixtures are written from the documented format and from `virt-viewer`'s parser, not captured from a live cluster. Ask the user to drop a real (expired, harmless) `.vv` into `Tests/SpiceCoreTests/Fixtures/` when one is available; the parser test should then be re-run against it unchanged.
2. **Migration messages.** `MAIN_MIGRATE_BEGIN`/`MAIN_MIGRATE_SWITCH_HOST` are emitted only by a cluster performing a live migration. The layout below is taken from `spice.proto`; the vendored headers under `Sources/CSpiceCodec/vendor/spice/` carry `enums.h` only, so **no local header confirms it**. Task 6 therefore parses defensively — every length is validated against the payload before use, and a message that does not parse is logged and dropped, never fatal to a working session.

## Protocol and format reference

### `.vv` (virt-viewer connection file), INI

```ini
[virt-viewer]
type=spice
host=192.168.1.10
port=0
tls-port=61000
password=<one-shot ticket, expires in ~30s>
host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com
ca=-----BEGIN CERTIFICATE-----\nMIIFxzCCA6+gAwIBAgIU...\n-----END CERTIFICATE-----\n
delete-this-file=1
title=VM 100 - win11
toggle-fullscreen=shift+f11
release-cursor=shift+f12
secure-attention=ctrl+alt+end
proxy=http://proxy.example.com:3128
```

- Section header `[virt-viewer]`; keys are case-insensitive; unknown keys ignored (forward compatibility).
- `ca` newlines are escaped as the two characters `\` `n`. Un-escape before PEM parsing.
- `port=0` means "no plain port" — TLS only. Treat `0` as absent.
- `host-subject` RDN order matches the certificate's DER order (Proxmox emits `OU,O,CN`).
- `delete-this-file=1` asks the client to delete the file after connecting.
- We consume: `host`, `port`, `tls-port`, `password`, `host-subject`, `ca`, `delete-this-file`, `title`. `proxy`, `toggle-fullscreen`, `release-cursor`, `secure-attention` are out of scope (spec §1) and ignored.

### Subject matching (what spice-gtk does)

`spice-common/common/ssl_verify.c` parses the expected `host-subject` into an X509 name and compares it with the peer certificate's subject **entry by entry, in order**: same number of entries, same attribute at each position, same value. It is not a substring match and not order-insensitive. Our implementation must be equivalent.

OID → short name map needed for the comparison:

```
2.5.4.3  CN     2.5.4.6  C      2.5.4.7  L      2.5.4.8  ST     2.5.4.9  STREET
2.5.4.10 O      2.5.4.11 OU     2.5.4.5  serialNumber
0.9.2342.19200300.100.1.25 DC   1.2.840.113549.1.9.1 emailAddress
```

### Migration messages (from `spice.proto`; **unverified locally** — see above)

```
MAIN_MIGRATE_BEGIN       = 101   SpiceMigrationDstInfo
MAIN_MIGRATE_CANCEL      = 102   (empty)
MAIN_MIGRATE_SWITCH_HOST = 111   SpiceMsgMainMigrationSwitchHost
MAIN_MIGRATE_END         = 112   (empty)

SpiceMigrationDstInfo / MigrationSwitchHost body:
    u32 port
    u32 sport                    (TLS port; 0 or 0xFFFFFFFF = none)
    u32 host_size                (includes the NUL terminator)
    u32 host_offset              (byte offset from the start of the message body)
    u32 cert_subject_size        (0 when absent; includes NUL when present)
    u32 cert_subject_offset
    … pointed-to bytes elsewhere in the body …

client → server:
MAIN_MIGRATE_CONNECTED     = 102
MAIN_MIGRATE_CONNECT_ERROR = 103
MAIN_MIGRATE_END           = 109
```

Pointer-style fields use the same `reader(at:)` mechanism `SpiceImage` already uses. **Validate before trusting:** each offset must be inside the payload, each size ≤ payload length, and the strings must be NUL-terminated within their declared size. Sizes above 4 KiB are rejected. We do not implement seamless migration (spec §3: "Full channel switchover is deferred") — we surface the prompt and reconnect.

## File Structure

```
Sources/
  SpiceCore/
    VVFile.swift          INI parse → VVFile value type; CA un-escaping; validation
    Certificates.swift    PEM → [SecCertificate]; subject DN components; host-subject match
    TLSPolicy.swift       what the transport needs to verify a peer: anchors + expected subject
    SpiceError.swift      + TLSFailure detail on .tls
    NWTransport.swift     + connect(host:port:tls:) with the verify block
    MainChannel.swift     + migration message forwarding (already streams MainMessage)
  SpiceWire/
    MainMessages.swift    + MigrationTarget, .migrateBegin/.migrateSwitchHost cases
  SpiceKit/
    SpiceSession.swift    ConnectionConfig gains TLS; SessionEvent.migrated
    ConnectFailureKind.swift  + hostSubjectMismatch carries expected/presented
  spicesee-cli/main.swift + `vv <file>` and `--tls` flags
  SpiceSee/
    SessionBackend.swift  connect(...) takes a ConnectionTarget; ConnectFailure gains real subjects
    SpiceKitBackend.swift TLS + migration mapping; .step(.tls)
    SessionModel.swift    passes the target through
    Models.swift          SavedConnection gains hostSubject/caPEM (Codable, optional)
    VVDocument.swift      opening a .vv: parse → connect → honour delete-this-file
    SpiceSeeApp.swift     NSApplicationDelegateAdaptor for document open; drops the stopgap parser
Tests/
  SpiceCoreTests/  VVFileTests.swift  CertificatesTests.swift  (+ Fixtures/*.vv, *.pem)
  SpiceWireTests/  MigrationMessageTests.swift
  SpiceKitTests/   TLSFailureTests.swift  MigrationSessionTests.swift
scripts/dev-tls.sh        generates the test CA + server cert, prints the socat command
```

---

### Task 1: `.vv` file parsing

**Files:**
- Create: `Sources/SpiceCore/VVFile.swift`
- Create: `Tests/SpiceCoreTests/VVFileTests.swift`
- Create: `Tests/SpiceCoreTests/Fixtures/proxmox.vv`, `Tests/SpiceCoreTests/Fixtures/plain.vv`

**Interfaces:**
- Consumes: `SpiceError`.
- Produces: `public struct VVFile: Sendable, Equatable` with `host: String`, `port: UInt16?`, `tlsPort: UInt16?`, `password: String?`, `hostSubject: String?`, `caPEM: String?`, `title: String?`, `deleteAfterConnecting: Bool`; `public static func parse(_ text: String) throws -> VVFile`; `public static func parse(contentsOf: URL) throws -> VVFile`.

- [ ] **Step 1: Write the fixtures**

`Tests/SpiceCoreTests/Fixtures/proxmox.vv` — the shape Proxmox emits (one line, escaped CA; the certificate body is a real but throwaway self-signed cert, generated in Task 2's Step 1 and pasted here; until then use the placeholder below and update it in Task 2):

```ini
[virt-viewer]
type=spice
host=192.168.1.10
port=0
tls-port=61000
password=Zm9vYmFyLXRpY2tldA==
host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com
ca=-----BEGIN CERTIFICATE-----\nMIIB<<placeholder>>\n-----END CERTIFICATE-----\n
delete-this-file=1
title=VM 100 - win11 (Press %s to release the cursor)
toggle-fullscreen=shift+f11
release-cursor=shift+f12
secure-attention=ctrl+alt+end
```

`Tests/SpiceCoreTests/Fixtures/plain.vv` — a non-Proxmox, non-TLS file:

```ini
[virt-viewer]
type=spice
host=10.0.0.4
port=5900
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/SpiceCoreTests/VVFileTests.swift
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
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter VVFileTests`
Expected: compile error — `VVFile` does not exist.

- [ ] **Step 4: Implement**

```swift
// Sources/SpiceCore/VVFile.swift
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
        let data = try Data(contentsOf: url)
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
        guard inSection || !fields.isEmpty else { throw SpiceError(.vvFile("no [virt-viewer] section")) }
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
```

Add the error case in `Sources/SpiceCore/SpiceError.swift` — one line in `Kind`:

```swift
        case connect, tls, link(LinkError), auth, protocolError(WireError), closed, unsupported(String)
        case vvFile(String)
```

(`SpiceError(.vvFile(…))` needs no channel; the existing `init` already defaults it.)

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --filter VVFileTests`
Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpiceCore/VVFile.swift Sources/SpiceCore/SpiceError.swift \
        Tests/SpiceCoreTests/VVFileTests.swift Tests/SpiceCoreTests/Fixtures
git commit -m "feat(core): parse virt-viewer .vv connection files"
```

---

### Task 2: Certificates — PEM decoding, subject DNs, host-subject matching

**Files:**
- Create: `Sources/SpiceCore/Certificates.swift`
- Create: `Tests/SpiceCoreTests/CertificatesTests.swift`
- Create: `Tests/SpiceCoreTests/Fixtures/test-ca.pem`, `test-server.pem` (generated in Step 1)
- Create: `scripts/dev-tls.sh`
- Modify: `Tests/SpiceCoreTests/Fixtures/proxmox.vv` (paste the real CA)

**Interfaces:**
- Consumes: `SpiceError`, Security.framework.
- Produces: `public enum Certificates` with `static func parsePEM(_ pem: String) throws -> [SecCertificate]`, `static func subjectComponents(of: SecCertificate) throws -> [(attribute: String, value: String)]`, `static func subjectDN(of: SecCertificate) throws -> String`, `static func matches(hostSubject: String, certificate: SecCertificate) throws -> Bool`, `static func parseSubject(_ dn: String) -> [(attribute: String, value: String)]`.

- [ ] **Step 1: Generate the test certificates**

`scripts/dev-tls.sh` — creates a throwaway CA and a server certificate whose subject is Proxmox-shaped, and prints the `socat` line Task 5 uses. Idempotent; writes into a directory given as `$1` (default `.dev-tls`, gitignored).

```bash
#!/bin/sh
# Generates a throwaway CA + server cert for exercising SpiceSee's TLS path against a real
# OpenSSL endpoint. Nothing here is a secret; the key never leaves the dev machine.
set -eu
DIR="${1:-.dev-tls}"
SUBJECT="/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=pve1.example.com"
mkdir -p "$DIR"
cd "$DIR"

if [ ! -f ca.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/O=PVE Cluster Manager CA/CN=Proxmox Virtual Environment Cluster Manager CA" \
    -keyout ca.key -out ca.pem 2>/dev/null
fi

if [ ! -f server.pem ]; then
  openssl req -newkey rsa:2048 -nodes -subj "$SUBJECT" -keyout server.key -out server.csr 2>/dev/null
  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -days 3650 -out server.pem 2>/dev/null
  cat server.key server.pem > server-bundle.pem
fi

# A second CA the server does NOT use, for the "wrong CA is rejected" test.
if [ ! -f other-ca.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/O=Someone Else/CN=Someone Else CA" -keyout other-ca.key -out other-ca.pem 2>/dev/null
fi

echo "CA:            $DIR/ca.pem"
echo "server bundle: $DIR/server-bundle.pem"
echo "host-subject:  OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com"
echo
echo "On the dev box, wrap the SPICE port in TLS:"
echo "  socat OPENSSL-LISTEN:5931,cert=server-bundle.pem,verify=0,reuseaddr,fork TCP:127.0.0.1:5930"
```

Run it, then copy `ca.pem` → `Tests/SpiceCoreTests/Fixtures/test-ca.pem` and `server.pem` → `Tests/SpiceCoreTests/Fixtures/test-server.pem`, and paste the CA into `proxmox.vv`'s `ca=` line with newlines escaped:

```bash
chmod +x scripts/dev-tls.sh && ./scripts/dev-tls.sh
cp .dev-tls/ca.pem Tests/SpiceCoreTests/Fixtures/test-ca.pem
cp .dev-tls/server.pem Tests/SpiceCoreTests/Fixtures/test-server.pem
python3 - <<'EOF'
import re, pathlib
ca = pathlib.Path('Tests/SpiceCoreTests/Fixtures/test-ca.pem').read_text()
vv = pathlib.Path('Tests/SpiceCoreTests/Fixtures/proxmox.vv')
text = re.sub(r'^ca=.*$', 'ca=' + ca.replace('\n', '\\n'), vv.read_text(), flags=re.M)
vv.write_text(text)
EOF
```

Add `.dev-tls/` to `.gitignore`. Verify the subject reads back as expected:

```bash
openssl x509 -in Tests/SpiceCoreTests/Fixtures/test-server.pem -noout -subject -nameopt RFC2253
```
Expected: `subject=CN=pve1.example.com,O=Proxmox Virtual Environment,OU=PVE Cluster Node` (RFC2253 prints reversed; the DER order is OU, O, CN — that is what `host-subject` uses).

If the Mac's `openssl` is LibreSSL and rejects a flag, use the dev box instead (`ssh aaron@192.168.50.6`, OpenSSL 3.0.13) and `scp` the results back; say which you used.

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/SpiceCoreTests/CertificatesTests.swift
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
    let chain = try Certificates.parsePEM(try pem("test-ca.pem") + try pem("test-server.pem"))
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
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter CertificatesTests`
Expected: compile error — `Certificates` does not exist.

- [ ] **Step 4: Implement**

```swift
// Sources/SpiceCore/Certificates.swift
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
        return entries.compactMap { entry in
            guard let oid = entry[kSecPropertyKeyLabel as String] as? String,
                  let value = entry[kSecPropertyKeyValue as String] as? String else { return nil }
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

    /// Splits "OU=a,O=b,CN=c" on unescaped commas, then on the FIRST '=' of each component, so a
    /// value may itself contain '='. Returns [] for anything that is not in that shape.
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
```

This references `SpiceError.tls(TLSFailure)` — Task 3 defines it. Implement Task 3's error change **first if the compiler complains**; the two tasks were split for review size, not for build order, so it is fine to land the `Kind` change here and let Task 3 build the rest on it. Say which you did in your report.

- [ ] **Step 5: Run**

Run: `swift test --filter CertificatesTests`
Expected: 6 tests pass. If `subjectComponents` returns OIDs instead of short names for some entry, extend the map rather than loosening the test.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpiceCore/Certificates.swift Tests/SpiceCoreTests/CertificatesTests.swift \
        Tests/SpiceCoreTests/Fixtures scripts/dev-tls.sh .gitignore
git commit -m "feat(core): PEM decoding and host-subject matching"
```

---
### Task 3: Structured TLS failures

The design's host-subject sheet shows *expected* and *presented* subjects. Today `SpiceError.tls` carries neither, and `SpiceKitBackend` fills the sheet with empty strings. This task gives the error the shape the UI already asks for.

**Files:**
- Modify: `Sources/SpiceCore/SpiceError.swift`
- Modify: `Sources/SpiceKit/ConnectFailureKind.swift`
- Modify: `Tests/SpiceKitTests/SpiceKitBackendTests.swift` (the existing `spiceErrorClassification` test)

**Interfaces:**
- Produces: `public enum TLSFailure: Sendable, Equatable` with `.handshake(String)`, `.untrusted(String)`, `.badCertificate(String)`, `.subjectMismatch(expected: String, presented: String)`; `SpiceError.Kind.tls(TLSFailure)`; `ConnectFailureKind.hostSubjectMismatch(expected: String, presented: String)`.

- [ ] **Step 1: Write the failing tests**

Replace the TLS line of `spiceErrorClassification` in `Tests/SpiceKitTests/SpiceKitBackendTests.swift` and add a case:

```swift
@Test func tlsFailuresCarryBothSubjects() {
    let mismatch = SpiceError(.tls(.subjectMismatch(expected: "CN=pve1", presented: "CN=pve3")))
    #expect(ConnectFailureKind.of(mismatch) == .hostSubjectMismatch(expected: "CN=pve1", presented: "CN=pve3"))
    // Everything else about TLS is a plain failure — the sheet has no detail box for it.
    #expect(ConnectFailureKind.of(SpiceError(.tls(.untrusted("not trusted")))) == .other)
    #expect(ConnectFailureKind.of(SpiceError(.tls(.badCertificate("bad")))) == .other)
    #expect(ConnectFailureKind.of(SpiceError(.tls(.handshake("reset")))) == .other)
}
```

and in the existing `spiceErrorClassification`, change

```swift
    #expect(ConnectFailureKind.of(SpiceError(.tls)) == .hostSubjectMismatch)
```

to

```swift
    #expect(ConnectFailureKind.of(SpiceError(.tls(.subjectMismatch(expected: "a", presented: "b"))))
            == .hostSubjectMismatch(expected: "a", presented: "b"))
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SpiceKitBackendTests`
Expected: compile error — `.tls` takes no argument yet.

- [ ] **Step 3: Implement**

`Sources/SpiceCore/SpiceError.swift`:

```swift
import SpiceWire

/// Why a TLS connection could not be trusted. `subjectMismatch` carries both subjects because the
/// design's failure sheet shows them — they are certificate facts, not SPICE error codes.
public enum TLSFailure: Error, Sendable, Equatable {
    case handshake(String)
    case untrusted(String)
    case badCertificate(String)
    case subjectMismatch(expected: String, presented: String)
}

public struct SpiceError: Error, Sendable {
    public enum Kind: Sendable {
        case connect, tls(TLSFailure), link(LinkError), auth, protocolError(WireError), closed
        case unsupported(String), vvFile(String)
    }
    public var kind: Kind
    public var channel: ChannelDescriptor?
    public var underlying: String?
    public init(_ kind: Kind, channel: ChannelDescriptor? = nil, underlying: String? = nil) {
        self.kind = kind; self.channel = channel; self.underlying = underlying
    }
}
```

`Sources/SpiceKit/ConnectFailureKind.swift`:

```swift
public enum ConnectFailureKind: Sendable, Equatable {
    case passwordRejected
    case refused
    case hostSubjectMismatch(expected: String, presented: String)
    case other

    public static func of(_ error: SpiceError) -> ConnectFailureKind {
        switch error.kind {
        case .auth, .link(.permissionDenied): .passwordRejected
        case .connect: .refused
        case let .tls(.subjectMismatch(expected, presented)): .hostSubjectMismatch(expected: expected, presented: presented)
        default: .other
        }
    }
}
```

Then fix the one call site in `Sources/SpiceSee/SpiceKitBackend.swift`:

```swift
        case let .hostSubjectMismatch(expected, presented):
            .hostSubjectMismatch(expected: expected, presented: presented, host: endpoint)
```

- [ ] **Step 4: Run**

Run: `swift test --filter SpiceKitTests` then `swift test 2>&1 | tail -1`
Expected: all pass. The app is not built by SPM; it is rebuilt in Task 8.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceCore/SpiceError.swift Sources/SpiceKit/ConnectFailureKind.swift \
        Sources/SpiceSee/SpiceKitBackend.swift Tests/SpiceKitTests/SpiceKitBackendTests.swift
git commit -m "feat(core,kit): TLS failures carry the expected and presented subject"
```

---

### Task 4: TLS transport

**Files:**
- Create: `Sources/SpiceCore/TLSPolicy.swift`
- Modify: `Sources/SpiceCore/NWTransport.swift`
- Create: `Tests/SpiceCoreTests/TLSPolicyTests.swift`

**Interfaces:**
- Consumes: `Certificates`, `TLSFailure`, Network.framework.
- Produces: `public struct TLSPolicy: Sendable` with `init(caPEM: String?, hostSubject: String?) throws`, `anchors: [SecCertificate]`, `hostSubject: String?`, and `func verify(peerChain: [SecCertificate]) -> TLSFailure?` (nil = trusted); `NWTransport.connect(host:port:tls:)` with `tls: TLSPolicy? = nil`.

Splitting `verify` out of the `sec_protocol` callback is what makes this testable: the callback does the plumbing, `verify` holds every decision, and the tests drive `verify` directly with the fixture certificates.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SpiceCoreTests/TLSPolicyTests.swift
import Foundation
import Security
import Testing
@testable import SpiceCore

private func certificates(_ name: String) throws -> [SecCertificate] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return try Certificates.parsePEM(try String(contentsOf: url, encoding: .utf8))
}

private let proxmoxSubject = "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com"

@Test func trustsAChainSignedByTheFileSCA() throws {
    let policy = try TLSPolicy(caPEM: try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/test-ca.pem"), encoding: .utf8),
        hostSubject: proxmoxSubject)
    #expect(policy.verify(peerChain: try certificates("test-server.pem")) == nil)
}

@Test func rejectsAMismatchedSubjectWithBothNames() throws {
    let policy = try TLSPolicy(caPEM: try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/test-ca.pem"), encoding: .utf8),
        hostSubject: "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve3.example.com")
    guard case let .subjectMismatch(expected, presented)? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected a subject mismatch"); return
    }
    #expect(expected == "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve3.example.com")
    #expect(presented == proxmoxSubject)
}

@Test func rejectsAChainTheCADidNotSign() throws {
    // The "other" CA signed nothing in this chain, so evaluation must fail before the subject check.
    let other = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/other-ca.pem"), encoding: .utf8)
    let policy = try TLSPolicy(caPEM: other, hostSubject: proxmoxSubject)
    guard case .untrusted? = policy.verify(peerChain: try certificates("test-server.pem")) else {
        Issue.record("expected untrusted"); return
    }
}

@Test func rejectsAnEmptyChain() throws {
    let policy = try TLSPolicy(caPEM: try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/test-ca.pem"), encoding: .utf8),
        hostSubject: nil)
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
```

Copy `other-ca.pem` into the fixtures in this task's Step 1 if Task 2 did not:
```bash
cp .dev-tls/other-ca.pem Tests/SpiceCoreTests/Fixtures/other-ca.pem
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TLSPolicyTests`
Expected: compile error — `TLSPolicy` does not exist.

- [ ] **Step 3: Implement the policy**

```swift
// Sources/SpiceCore/TLSPolicy.swift
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
            let reason = (error as Error?).map { String(describing: $0.localizedDescription) } ?? "not trusted"
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
```

- [ ] **Step 4: Run the policy tests**

Run: `swift test --filter TLSPolicyTests`
Expected: 6 pass. If `rejectsAChainTheCADidNotSign` comes back `nil` rather than `.untrusted`, `SecTrustSetAnchorCertificatesOnly` is not taking effect — do not weaken the test; that is the bug the whole feature exists to prevent.

- [ ] **Step 5: Wire the policy into the transport**

In `Sources/SpiceCore/NWTransport.swift`, replace the `connect` body's parameter list and connection construction:

```swift
    public static func connect(host: String, port: UInt16, tls: TLSPolicy? = nil) async throws -> NWTransport {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw SpiceError(.connect, underlying: "bad port") }
        let parameters: NWParameters
        // The verify block's outcome has to reach the `connect` continuation, and the block is a C
        // callback that can only answer yes/no. A small actor carries the reason across.
        let verdict = TLSVerdict()
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let chain: [SecCertificate]
                if #available(macOS 12.0, *) {
                    chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
                } else {
                    chain = []
                }
                let failure = tls.verify(peerChain: chain)
                if let failure { Task { await verdict.record(failure) } }
                complete(failure == nil)
            }, DispatchQueue(label: "com.spicesee.tls"))
            parameters = NWParameters(tls: options, tcp: .init())
        } else {
            parameters = .tcp
        }

        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters)
        do {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                nonisolated(unsafe) var resumed = false
                c.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; k.resume()
                    case .failed(let e): resumed = true; k.resume(throwing: SpiceError(.connect, underlying: e.localizedDescription))
                    case .waiting(let e): resumed = true; c.cancel(); k.resume(throwing: SpiceError(.connect, underlying: e.localizedDescription))
                    default: break
                    }
                }
                c.start(queue: DispatchQueue(label: "com.spicesee.nw"))
            }
        } catch {
            // A rejected certificate surfaces as a generic connection failure; the verify block knows
            // the real reason, so prefer it.
            if let failure = await verdict.failure { throw SpiceError(.tls(failure)) }
            throw error
        }
        c.stateUpdateHandler = nil
        return NWTransport(connection: c)
    }
```

and add, at the end of the file:

```swift
/// Carries the verify block's reason out to whoever is awaiting the connection.
private actor TLSVerdict {
    private(set) var failure: TLSFailure?
    func record(_ f: TLSFailure) { if failure == nil { failure = f } }
}
```

`SecTrustCopyCertificateChain` is macOS 12+; the deployment target is 14, so the availability check is belt and braces — if the compiler is satisfied without it, drop the `#available` and use the call directly, and say so in your report.

The `Task { await verdict.record(failure) }` inside a synchronous C callback is a fire-and-forget hop; the `complete(false)` that follows tears the connection down and the `catch` above then awaits `verdict.failure`. If a race shows up in Task 5's live run (a rejected connection reported as `.connect` rather than `.tls`), make `TLSVerdict` a small `final class` guarded by the callback queue's serialisation instead — but only if the live evidence demands it, and record it as a deviation.

- [ ] **Step 6: Build and run everything**

Run: `swift build && swift test 2>&1 | tail -1`
Expected: builds; all tests pass. The transport's TLS path is exercised for real in Task 5.

- [ ] **Step 7: Commit**

```bash
git add Sources/SpiceCore/TLSPolicy.swift Sources/SpiceCore/NWTransport.swift Tests/SpiceCoreTests
git commit -m "feat(core): TLS transport pinned to the .vv CA and host-subject"
```

---

### Task 5: `ConnectionConfig`, the CLI, and a real TLS endpoint

This is the cross-implementation check: a real OpenSSL server, holding a real certificate chain, in front of the real SPICE server. It proves the verify block accepts what it should and — more importantly — rejects what it must.

**Files:**
- Modify: `Sources/SpiceKit/SpiceSession.swift` (`ConnectionConfig`)
- Modify: `Sources/spicesee-cli/main.swift`
- Modify: `docs/dev-server.md`

**Interfaces:**
- Produces: `ConnectionConfig(host:port:tlsPort:password:hostSubject:caPEM:)` with `port`/`tlsPort` optional and at least one required; `ConnectionConfig(vv: VVFile)`; `spicesee-cli vv <file> [seconds out.png]`, and `--tls-port/--ca/--host-subject` on `connect`.

- [ ] **Step 1: Extend `ConnectionConfig`**

```swift
public struct ConnectionConfig: Sendable {
    public var host: String
    public var port: UInt16?
    public var tlsPort: UInt16?
    public var password: String?
    public var hostSubject: String?
    public var caPEM: String?

    public init(host: String, port: UInt16? = nil, tlsPort: UInt16? = nil, password: String? = nil,
                hostSubject: String? = nil, caPEM: String? = nil) {
        self.host = host; self.port = port; self.tlsPort = tlsPort; self.password = password
        self.hostSubject = hostSubject; self.caPEM = caPEM
    }

    public init(vv: VVFile) {
        self.init(host: vv.host, port: vv.port, tlsPort: vv.tlsPort, password: vv.password,
                  hostSubject: vv.hostSubject, caPEM: vv.caPEM)
    }

    /// TLS wins when the file offers both: a Proxmox `.vv` carries `tls-port` precisely because the
    /// console is meant to be encrypted.
    public var usesTLS: Bool { tlsPort != nil }
}
```

and in `SpiceSession.connect(_:)`:

```swift
    public static func connect(_ config: ConnectionConfig) async throws -> SpiceSession {
        let policy = config.usesTLS ? try TLSPolicy(caPEM: config.caPEM, hostSubject: config.hostSubject) : nil
        guard let port = config.tlsPort ?? config.port else {
            throw SpiceError(.connect, underlying: "no port")
        }
        return try await connect(password: config.password) { _ in
            try await NWTransport.connect(host: config.host, port: port, tls: policy)
        }
    }
```

Every channel dials the same port and policy, which is what spice-gtk does: the server hands out one TLS port for all channels.

- [ ] **Step 2: Extend the CLI**

Rewrite `Sources/spicesee-cli/main.swift`'s usage and add a `vv` subcommand plus TLS flags on `connect`:

```
usage: spicesee-cli connect <host> <port> [password] [--tls-port <p>] [--ca <file.pem>] [--host-subject <s>]
       spicesee-cli dump <host> <port> <seconds> <out.png> [password]
       spicesee-cli vv <file.vv> [seconds out.png]
```

`vv` parses the file with `VVFile.parse(contentsOf:)`, prints what it found (host, ports, whether a CA and host-subject are present, and **never** the password), connects via `ConnectionConfig(vv:)`, prints `MAIN_INIT` and the channel list, and — when `seconds` and `out.png` are given — captures a PNG the way `dump` does. A `.vv`'s ticket usually expires in ~30 s, so print a clear error when the link is refused rather than a raw dump.

Keep the existing argument handling style (positional, `usage()` on anything unexpected). `--ca` reads the PEM from a file so a shell never holds a certificate.

- [ ] **Step 3: Stand up the TLS endpoint**

On the Mac:

```bash
./scripts/dev-tls.sh                    # idempotent; .dev-tls/ is gitignored
scp .dev-tls/server-bundle.pem aaron@192.168.50.6:/tmp/spicesee-server.pem
```

On the box, wrap the SPICE port (run in the background; kill it when done):

```bash
ssh aaron@192.168.50.6 'nohup socat OPENSSL-LISTEN:5931,cert=/tmp/spicesee-server.pem,verify=0,reuseaddr,fork TCP:127.0.0.1:5930 >/tmp/socat.log 2>&1 & echo started'
ssh aaron@192.168.50.6 'ss -lnt | grep 5931 || cat /tmp/socat.log'
```

- [ ] **Step 4: Prove the positive case**

Write a `.vv` pointing at it (the CA is the one `dev-tls.sh` made):

```bash
python3 - <<'EOF'
import pathlib
ca = pathlib.Path('.dev-tls/ca.pem').read_text().replace('\n', '\\n')
pathlib.Path('/tmp/dev.vv').write_text(
    "[virt-viewer]\ntype=spice\nhost=192.168.50.6\nport=0\ntls-port=5931\n"
    "host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com\n"
    f"ca={ca}\n")
EOF
swift run spicesee-cli vv /tmp/dev.vv
```

Expected: the `MAIN_INIT` line and the ten-channel list, exactly as the plain-TCP `connect` prints — over TLS, through a foreign TLS implementation, with the chain pinned to the file's CA. Quote the output in your report.

Then capture a frame to prove the whole stack works over TLS:

```bash
swift run spicesee-cli vv /tmp/dev.vv 5 /tmp/tls.png
```

Look at the PNG with the Read tool and say what is on screen.

- [ ] **Step 5: Prove both negative cases**

```bash
sed 's/CN=pve1.example.com/CN=pve3.example.com/' /tmp/dev.vv > /tmp/wrong-subject.vv
swift run spicesee-cli vv /tmp/wrong-subject.vv        # expect: subject mismatch, both names printed
python3 - <<'EOF'
import pathlib
ca = pathlib.Path('.dev-tls/other-ca.pem').read_text().replace('\n', '\\n')
text = pathlib.Path('/tmp/dev.vv').read_text().splitlines()
out = [l for l in text if not l.startswith('ca=')] + [f'ca={ca}']
pathlib.Path('/tmp/wrong-ca.vv').write_text('\n'.join(out) + '\n')
EOF
swift run spicesee-cli vv /tmp/wrong-ca.vv             # expect: untrusted, NOT a subject mismatch
```

Both must fail, and fail with the *right* reason. A wrong-CA file reported as a subject mismatch means the trust evaluation is being skipped — stop and fix it. Quote both outputs.

- [ ] **Step 6: Tear down and document**

```bash
ssh aaron@192.168.50.6 'pkill -f "OPENSSL-LISTEN:5931" && echo stopped'
```

Add a `## TLS dev endpoint` section to `docs/dev-server.md`: what `scripts/dev-tls.sh` makes, the `socat` line, the three `spicesee-cli vv` invocations and their expected outcomes, and the note that this proves the verify block against OpenSSL but **not** against a real Proxmox cluster (no ticket flow, no cluster CA).

- [ ] **Step 7: Commit**

```bash
git add Sources/SpiceKit/SpiceSession.swift Sources/spicesee-cli/main.swift docs/dev-server.md
git commit -m "feat(kit,cli): connect from a .vv over TLS; verified against an OpenSSL endpoint"
```

---
### Task 6: Migration messages

**Files:**
- Modify: `Sources/SpiceWire/MainMessages.swift`
- Modify: `Sources/SpiceKit/SpiceSession.swift`
- Create: `Tests/SpiceWireTests/MigrationMessageTests.swift`
- Create: `Tests/SpiceKitTests/MigrationSessionTests.swift`

**Interfaces:**
- Produces: `public struct MigrationTarget: Sendable, Equatable` (`host: String`, `port: UInt16?`, `tlsPort: UInt16?`, `certSubject: String?`); `MainMessage.migrateBegin(MigrationTarget)`, `.migrateSwitchHost(MigrationTarget)`, `.migrateCancel`, `.migrateEnd`; `SessionEvent.migrated(MigrationTarget)`.

Read the "Migration messages" note in **What cannot be verified** before starting: the layout is from `spice.proto` and no local header confirms it. Parse defensively; never trap; never tear down a working session because a migration message did not parse.

- [ ] **Step 1: Write the failing wire tests**

```swift
// Tests/SpiceWireTests/MigrationMessageTests.swift
import Testing
@testable import SpiceWire

/// Builds a migration body: six u32 header words, then the pointed-to strings.
private func body(port: UInt32, sport: UInt32, host: String?, subject: String?) -> [UInt8] {
    var w = SpiceWriter()
    let hostBytes = host.map { Array($0.utf8) + [0] } ?? []
    let subjectBytes = subject.map { Array($0.utf8) + [0] } ?? []
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MigrationMessageTests`
Expected: compile error — `MigrationTarget` does not exist.

- [ ] **Step 3: Implement the wire types**

Add to `Sources/SpiceWire/MainMessages.swift`:

```swift
/// Where the cluster moved this VM. `spice.proto` gives both a plain and a TLS port; either may be
/// absent (0, or 0xFFFFFFFF from older servers).
public struct MigrationTarget: Sendable, Equatable {
    public var host: String
    public var port: UInt16?
    public var tlsPort: UInt16?
    public var certSubject: String?
    public init(host: String, port: UInt16?, tlsPort: UInt16?, certSubject: String?) {
        self.host = host; self.port = port; self.tlsPort = tlsPort; self.certSubject = certSubject
    }

    /// Longest string we will take from a migration message. Hostnames and subjects are far shorter;
    /// the cap exists so a bad length cannot make us allocate.
    static let maxStringBytes = 4096

    /// The six-word header is followed by the pointed-to bytes. Every offset and size is checked
    /// against the payload before it is used — this message arrives from the server mid-session and
    /// a bad one must be a caught error, never a trap.
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        let plain = try r.u32(), secure = try r.u32()
        let hostSize = try r.u32(), hostOffset = try r.u32()
        let subjectSize = try r.u32(), subjectOffset = try r.u32()

        func string(size: UInt32, offset: UInt32, field: String) throws -> String? {
            guard size > 0 else { return nil }
            guard size <= UInt32(Self.maxStringBytes) else {
                throw WireError.badValue(field: "\(field)_size", value: UInt64(size))
            }
            var at = try body.reader(at: offset)
            let bytes = try at.bytes(Int(size))
            guard let nul = bytes.firstIndex(of: 0) else {
                throw WireError.badValue(field: "\(field)_terminator", value: UInt64(size))
            }
            return String(decoding: bytes[..<nul], as: UTF8.self)
        }

        guard let host = try string(size: hostSize, offset: hostOffset, field: "host"), !host.isEmpty else {
            throw WireError.badValue(field: "migration_host", value: UInt64(hostSize))
        }
        self.host = host
        certSubject = try string(size: subjectSize, offset: subjectOffset, field: "cert_subject")
        port = Self.port(plain)
        tlsPort = Self.port(secure)
    }

    private static func port(_ value: UInt32) -> UInt16? {
        guard value > 0, value <= UInt32(UInt16.max) else { return nil }
        return UInt16(value)
    }
}
```

and in `MainMessage`, add the cases and their parsing:

```swift
    case migrateBegin(MigrationTarget)
    case migrateSwitchHost(MigrationTarget)
    case migrateCancel
    case migrateEnd
```

```swift
        case .migrateBegin: self = .migrateBegin(try MigrationTarget(reader: &r, body: body))
        case .migrateSwitchHost: self = .migrateSwitchHost(try MigrationTarget(reader: &r, body: body))
        case .migrateCancel: self = .migrateCancel
        case .migrateEnd: self = .migrateEnd
```

`MainMessage.init` currently builds only `var r = SpiceReader(payload)`; add `let body = SpiceReader(payload)` beside it, mirroring `DisplayMessage.init`, so `reader(at:)` resolves offsets from the message start.

The two test helpers `isMigrateCancel`/`isMigrateEnd` are test-only sugar — put them in the test file, not the module:

```swift
private extension MainMessage {
    var isMigrateCancel: Bool { if case .migrateCancel = self { true } else { false } }
    var isMigrateEnd: Bool { if case .migrateEnd = self { true } else { false } }
}
```

- [ ] **Step 4: Run the wire tests**

Run: `swift test --filter MigrationMessageTests`
Expected: 5 pass.

- [ ] **Step 5: Write the failing session test**

```swift
// Tests/SpiceKitTests/MigrationSessionTests.swift
import Foundation
import Testing
import SpiceWire
import SpiceCore
@testable import SpiceKit

@Test func switchHostBecomesAMigratedEvent() async throws {
    var switchBody = SpiceWriter()
    let host = Array("pve3.lan".utf8) + [0]
    switchBody.u32(5900); switchBody.u32(5901)
    switchBody.u32(UInt32(host.count)); switchBody.u32(24)
    switchBody.u32(0); switchBody.u32(0)
    switchBody.bytes(host)

    var mi = SpiceWriter(); [1, 1, 1, 1, 0, 10, 0, 0].forEach { mi.u32(UInt32($0)) }
    var cl = SpiceWriter(); cl.u32(0)
    let main = InMemoryTransport(input: try fakeLink(body:
        frame(MainServerMsg.`init`.rawValue, mi.bytes)
        + frame(MainServerMsg.channelsList.rawValue, cl.bytes)
        + frame(MainServerMsg.migrateSwitchHost.rawValue, switchBody.bytes)))

    let session = try await SpiceSession.connect(password: nil) { _ in main }
    var targets: [MigrationTarget] = []
    for await e in session.events {
        if case let .migrated(t) = e { targets.append(t) }
        if case .disconnected = e { break }
    }
    #expect(targets == [MigrationTarget(host: "pve3.lan", port: 5900, tlsPort: 5901, certSubject: nil)])
}

@Test func anUnparseableMigrationMessageDoesNotEndTheSession() async throws {
    var mi = SpiceWriter(); [1, 1, 1, 1, 0, 10, 0, 0].forEach { mi.u32(UInt32($0)) }
    var cl = SpiceWriter(); cl.u32(0)
    var mm = SpiceWriter(); mm.u32(777)
    let main = InMemoryTransport(input: try fakeLink(body:
        frame(MainServerMsg.`init`.rawValue, mi.bytes)
        + frame(MainServerMsg.channelsList.rawValue, cl.bytes)
        + frame(MainServerMsg.migrateSwitchHost.rawValue, [0, 0, 0])      // truncated: dropped
        + frame(MainServerMsg.multiMediaTime.rawValue, mm.bytes)))        // still delivered after it

    let session = try await SpiceSession.connect(password: nil) { _ in main }
    var migrated = 0, disconnected = false
    for await e in session.events {
        if case .migrated = e { migrated += 1 }
        if case .disconnected = e { disconnected = true; break }
    }
    #expect(migrated == 0 && disconnected)
}
```

`MainChannel`'s pump already drops messages that fail to parse (`if let m = try? MainMessage(...)`), which is what makes the second test pass — confirm that is still true rather than assuming it.

- [ ] **Step 6: Implement the session event**

In `Sources/SpiceKit/SpiceSession.swift`, add `case migrated(MigrationTarget)` to `SessionEvent` and handle both messages in `handleMain`:

```swift
        case let .migrateSwitchHost(target): cont.yield(.migrated(target))
        // A begin without a switch means the server is preparing a migration it may still cancel;
        // the design's prompt belongs on the switch, so log and wait.
        case let .migrateBegin(target): log.notice("migration announced to \(target.host, privacy: .public)")
        case .migrateCancel, .migrateEnd: break
```

- [ ] **Step 7: Run**

Run: `swift test --filter MigrationSessionTests` then `swift test 2>&1 | tail -1`
Expected: 2 new pass; whole suite green.

- [ ] **Step 8: Commit**

```bash
git add Sources/SpiceWire/MainMessages.swift Sources/SpiceKit/SpiceSession.swift \
        Tests/SpiceWireTests/MigrationMessageTests.swift Tests/SpiceKitTests/MigrationSessionTests.swift
git commit -m "feat(wire,kit): parse migration targets and surface them as an event"
```

---

### Task 7: `SavedConnection` carries TLS material

**Files:**
- Modify: `Sources/SpiceSee/Models.swift`
- Create: `Tests/SpiceKitTests/…` — none; this is app-side storage, verified by the app build and by Task 9's round trip.

**Interfaces:**
- Produces: `SavedConnection.hostSubject: String?`, `SavedConnection.caPEM: String?`, `SavedConnection.init(vv:)`.

- [ ] **Step 1: Extend the model**

In `Sources/SpiceSee/Models.swift`, add two properties to `SavedConnection` (both `Optional`, so Swift's synthesized `Decodable` treats them as absent in the existing `connections.json` — **do not** add a custom `init(from:)`):

```swift
    /// From a `.vv`: the certificate subject the server must present, and the CA that signs it.
    /// Persisted so a saved Proxmox connection still verifies on the next launch.
    var hostSubject: String?
    var caPEM: String?
```

and an initialiser that mirrors a parsed file:

```swift
extension SavedConnection {
    /// A connection made from a `.vv`. The ticket is deliberately not stored: Proxmox tickets expire
    /// within seconds, so a saved one is worse than none.
    init(vv: VVFile, name: String) {
        self.init(name: name, host: vv.host, port: vv.port ?? 0, tlsPort: vv.tlsPort)
        hostSubject = vv.hostSubject
        caPEM = vv.caPEM
    }
}
```

`SavedConnection.port` is non-optional `UInt16` with a default of 5900; a TLS-only `.vv` has no plain port, so `vv.port ?? 0` records "none" and `endpoint`/`usesTLS` already prefer `tlsPort`. Check `sidebarSubtitle` renders acceptably with port 0 — it shows `host:0`; if that reads badly, make `sidebarSubtitle` use `tlsPort ?? port` the way `endpoint` does. That is a model change, not a view change.

This file imports nothing engine-side today; `VVFile` comes from `SpiceCore`, so add `import SpiceCore` at the top of `Models.swift` **only if** the initialiser lives there. Prefer instead to put `init(vv:)` in `Sources/SpiceSee/VVDocument.swift` (Task 9), which already imports the engine, and keep `Models.swift` engine-free. Do that.

- [ ] **Step 2: Verify the store still loads old files**

Write a throwaway check (do not commit it) that the existing on-disk JSON decodes with the new fields absent:

```bash
swift -e '
struct A: Codable { var id = UUID(); var name: String; var host: String; var hostSubject: String? }
let old = #"[{"id":"\#(UUID().uuidString)","name":"n","host":"h"}]"#
print((try? JSONDecoder().decode([A].self, from: Data(old.utf8))) != nil)
' 2>/dev/null || echo "run the equivalent check inside the app build"
```

The real check is Task 9's build plus launching the app and seeing the existing saved connections still listed. Do that there; note here if you could not.

- [ ] **Step 3: Commit**

```bash
git add Sources/SpiceSee/Models.swift
git commit -m "feat(app): saved connections remember their .vv CA and host-subject"
```

---

### Task 8: The seam — TLS material and migration cross `SessionBackend`

**Files:**
- Modify: `Sources/SpiceSee/SessionBackend.swift`, `Sources/SpiceSee/SpiceKitBackend.swift`, `Sources/SpiceSee/MockSessionBackend.swift`, `Sources/SpiceSee/SessionModel.swift`

**Interfaces:**
- Produces: `struct ConnectionTarget: Sendable` (`host`, `port: UInt16?`, `tlsPort: UInt16?`, `hostSubject: String?`, `caPEM: String?`, `password: String?`); `SessionBackend.connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent>` replacing the six-argument form; `BackendEvent.migrated` already exists.

- [ ] **Step 1: Replace the connect signature**

In `Sources/SpiceSee/SessionBackend.swift`:

```swift
/// Everything needed to open one session. Grouped rather than passed as six arguments because a
/// `.vv` file supplies most of it at once.
struct ConnectionTarget: Sendable {
    var host: String
    var port: UInt16?
    var tlsPort: UInt16?
    var hostSubject: String?
    var caPEM: String?
    var password: String?

    /// "pve1.lan:61000" — the TLS port when there is one, matching `SavedConnection.endpoint`.
    var endpoint: String { "\(host):\(tlsPort ?? port ?? 0)" }
    var usesTLS: Bool { tlsPort != nil }
}

protocol SessionBackend: Sendable {
    func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent>
    func disconnect() async
    func sendCtrlAltDel() async
    func sendInput(_ event: InputEvent)
}
```

- [ ] **Step 2: Update `SessionModel`**

`SessionModel.connect(_ connection: SavedConnection, password: String?)` builds the target:

```swift
        pump = Task { [backend] in
            let target = ConnectionTarget(host: connection.host,
                                          port: connection.port == 0 ? nil : connection.port,
                                          tlsPort: connection.tlsPort,
                                          hostSubject: connection.hostSubject,
                                          caPEM: connection.caPEM,
                                          password: password)
            for await event in backend.connect(target) { apply(event) }
        }
```

`acceptMigration(host:port:password:)` currently clears `tlsPort`. A migration target may carry a TLS port and a new cert subject; extend it to `acceptMigration(host:port:tlsPort:certSubject:password:)`, keeping the existing CA (the cluster CA does not change on migration) and replacing `hostSubject` when the message supplied one. The migration sheet calls it with what the offer holds — `MigrationOffer` gains `newTLSPort: UInt16?` and `certSubject: String?`; `MigrationPresenter` passes them through. **`MigrationSheet` itself does not change** — it already binds host and port text fields.

- [ ] **Step 3: Update the real backend**

`SpiceKitBackend.connect(_ target:)`:

```swift
    func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> {
        let endpoint = target.endpoint
        …
                    session = try await SpiceSession.connect(ConnectionConfig(
                        host: target.host, port: target.port, tlsPort: target.tlsPort,
                        password: target.password, hostSubject: target.hostSubject, caPEM: target.caPEM))
```

Yield `.step(.tls)` before `.step(.ticket)` **only when `target.usesTLS`** — the design's first step is "TLS handshake · host-subject verified", and claiming it on a plain-TCP connection would be a lie. `SpiceSession.connect` returning means the handshake and the verify block both succeeded, so the yield goes immediately after the `Task.isCancelled` guard.

Map the new event:

```swift
                    case let .migrated(t):
                        continuation.yield(.migrated(MigrationOffer(vmName: target.host,
                                                                    newHost: t.host,
                                                                    newPort: t.port ?? 0,
                                                                    newTLSPort: t.tlsPort,
                                                                    certSubject: t.certSubject)))
```

- [ ] **Step 4: Update the mock**

`MockSessionBackend.connect(_ target:)` takes the new type; `endpoint` comes from `target.endpoint`. The `certMismatch` scenario should now present plausible subjects in the same shape the real path produces (`OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com` expected vs `…CN=pve3.example.com` presented) so the sheet is reviewed against realistic strings. The `migrate` scenario's `MigrationOffer` gains the two new fields (`newTLSPort: 5901`, `certSubject: "CN=pve3,O=PVE Cluster Manager CA"`).

- [ ] **Step 5: Build and check every scenario**

```bash
xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "^\*\* BUILD"
swift test 2>&1 | tail -1
```

Then, per `CLAUDE.md`'s mock recipe (`SPICESEE_MOCK=1 <app>/Contents/MacOS/SpiceSee --scenario X --autoconnect`), screenshot and look at `--scenario certMismatch` (both subjects render in the detail box, not empty) and `--scenario migrate` (the sheet appears prefilled). Quit with `osascript`. Report what you saw.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpiceSee
git commit -m "feat(app): TLS material and migration targets cross the SessionBackend seam"
```

---

### Task 9: Opening a `.vv` connects

The M3 exit criterion. Double-clicking a `.vv` in Finder — which is how Proxmox's web UI hands off — must open a console.

**Files:**
- Create: `Sources/SpiceSee/VVDocument.swift`
- Modify: `Sources/SpiceSee/SpiceSeeApp.swift` (drop the stopgap `importVV`, add the delegate)

**Interfaces:**
- Produces: `@MainActor final class VVOpener` with `func open(_ url: URL, store: ConnectionStore, session: SessionModel, settings: AppSettings)`; `SavedConnection.init(vv:name:)`; `AppDelegate: NSObject, NSApplicationDelegate` handling `application(_:open:)`.

- [ ] **Step 1: Write the opener**

```swift
// Sources/SpiceSee/VVDocument.swift
import AppKit
import os
import SpiceCore

extension SavedConnection {
    /// A connection made from a `.vv`. The ticket is deliberately not stored: Proxmox tickets expire
    /// within seconds, so a saved one is worse than none.
    init(vv: VVFile, name: String) {
        self.init(name: name, host: vv.host, port: vv.port ?? 0, tlsPort: vv.tlsPort)
        hostSubject = vv.hostSubject
        caPEM = vv.caPEM
        savePasswordInKeychain = false
    }
}

/// Opens a `.vv` handed to us by Finder or the Proxmox web UI: parse, connect straight away, and —
/// if the file asked for it and the user has not turned it off — delete it afterwards.
@MainActor
final class VVOpener {
    private let log = Logger(subsystem: "com.spicesee", category: "vv")

    func open(_ url: URL, store: ConnectionStore, session: SessionModel, settings: AppSettings) {
        let vv: VVFile
        do {
            vv = try VVFile.parse(contentsOf: url)
        } catch {
            // The file is the user's only artefact here, so name it; the parser's reason is safe to
            // show (it never contains the ticket).
            log.error("\(url.lastPathComponent, privacy: .public): \(String(describing: error))")
            present(.other(title: "That file isn't a SPICE connection",
                           message: "SpiceSee could not read \(url.lastPathComponent). Download a fresh console file from the web UI."),
                    on: session)
            return
        }

        let name = vv.title.map(Self.cleanTitle) ?? vv.host
        var connection = SavedConnection(vv: vv, name: name)
        connection.lastConnected = Date()
        store.addImported(connection)
        session.connect(connection, password: vv.password)

        if vv.deleteAfterConnecting, settings.deleteVVAfterConnecting {
            // Proxmox marks these single-use; the ticket inside is spent either way.
            do { try FileManager.default.removeItem(at: url) }
            catch { log.notice("could not delete \(url.lastPathComponent, privacy: .public)") }
        }
    }

    /// Proxmox titles carry a virt-viewer hint: "VM 100 - win11 (Press %s to release the cursor)".
    static func cleanTitle(_ title: String) -> String {
        guard let paren = title.range(of: " (Press %s") else { return title }
        return String(title[title.startIndex ..< paren.lowerBound])
    }

    private func present(_ failure: ConnectFailure, on session: SessionModel) {
        session.presentFailure(failure)
    }
}
```

`SessionModel` needs one small addition so a file-level failure uses the same sheet as a connect failure:

```swift
    /// Shows a failure that happened before a connection was attempted (an unreadable `.vv`).
    func presentFailure(_ failure: ConnectFailure) { phase = .failed(failure) }
```

- [ ] **Step 2: Hook up document opening**

`SwiftUI`'s `Window` scene has no document handling, so use an app delegate. In `Sources/SpiceSee/SpiceSeeApp.swift`:

```swift
@main
struct SpiceSeeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    …
```

and, in the same file:

```swift
/// Finder and the Proxmox web UI hand `.vv` files to the app through the delegate, not through a
/// SwiftUI scene — `Window` has no document support.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the manager window once the app's state objects exist; a file opened during launch
    /// waits here until then.
    @MainActor static var openHandler: ((URL) -> Void)?
    @MainActor private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if let handler = Self.openHandler { handler(url) } else { Self.pending.append(url) }
            }
        }
    }

    @MainActor
    static func drainPending() {
        guard let handler = openHandler else { return }
        let urls = pending
        pending = []
        urls.forEach(handler)
    }
}
```

In the manager window's `.task`, install the handler and drain anything that arrived during launch:

```swift
                    AppDelegate.openHandler = { url in
                        openWindow(id: "manager")
                        opener.open(url, store: store, session: session, settings: settings)
                    }
                    AppDelegate.drainPending()
```

with `@State private var opener = VVOpener()` beside the other state. Replace the `Open .vv File…` menu action's `store.importVV(at:)` with the same `opener.open(...)`, and **delete** the stopgap `extension ConnectionStore { func importVV(at:) }` at the bottom of `SpiceSeeApp.swift` — `VVFile` replaces it.

- [ ] **Step 3: Build and test the open path**

```bash
xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "^\*\* BUILD"
```

Then, with the TLS endpoint from Task 5 running on the box, write `/tmp/dev.vv` (Task 5 Step 4) and open it with the built app:

```bash
open -a "<BUILT_PRODUCTS_DIR>/SpiceSee.app" /tmp/dev.vv
```

Expected: the app launches (or comes forward), the manager window shows a new connection named after the `.vv`, and a session window opens showing the Windows installer — **over TLS**. Screenshot the session window (`CGWindowListCopyWindowInfo` → `screencapture -l<id>`) and look at it. Then verify `/tmp/dev.vv` was deleted (the fixture sets `delete-this-file=1`; add it to the generated file if absent).

Also open a deliberately broken file and confirm the sheet appears rather than a crash:

```bash
printf '[virt-viewer]\nhost=\n' > /tmp/bad.vv && open -a "<…>/SpiceSee.app" /tmp/bad.vv
```

If `open -a` with a file argument does not deliver `application(_:open:)` on this machine, say so and try double-clicking from Finder (`open -R /tmp/dev.vv` to reveal it) — and if neither can be driven from here, hand it to the user with exact steps rather than claiming it works.

- [ ] **Step 4: Commit**

```bash
git add Sources/SpiceSee/VVDocument.swift Sources/SpiceSee/SpiceSeeApp.swift Sources/SpiceSee/SessionModel.swift
git commit -m "feat(app): opening a .vv file connects"
```

---

### Task 10: M3 exit — verification, docs, memory

**Files:**
- Modify: `CLAUDE.md`, `docs/dev-server.md`, this plan (tick the boxes, append execution notes)

- [ ] **Step 1: Full verification**

```bash
swift test 2>&1 | tail -1
scripts/check-vendored-notices.sh; echo exit=$?
xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "^\*\* BUILD"
swift build 2>&1 | grep -ci warning
```

Expected: all tests pass (109 at the start of M3 plus this milestone's), notices exit 0, `BUILD SUCCEEDED`, 0 warnings.

- [ ] **Step 2: Update `CLAUDE.md`**

Refresh the milestone paragraph: M3 shipped except what the "cannot be verified" list names; add a short **TLS and `.vv`** paragraph carrying the rules a future contributor would otherwise break —

- The `.vv` CA is the *only* anchor (`SecTrustSetAnchorCertificatesOnly`), and `host-subject` is compared entry-by-entry in DER order, as spice-gtk does. Not a hostname check.
- `TLSPolicy.verify` holds every trust decision so it can be tested without a socket; the `sec_protocol` verify block is plumbing only.
- Tickets are never persisted or logged.
- `scripts/dev-tls.sh` + `socat` on the dev box is how the TLS path is exercised; `.dev-tls/` is gitignored.

Keep the file's existing voice and length discipline.

- [ ] **Step 3: Update `docs/dev-server.md`**

Ensure the `## TLS dev endpoint` section from Task 5 is present and accurate, and add a `## M3 exit check (manual)` section: get a real `.vv` from a Proxmox web UI, double-click it, expect a console; then migrate the VM between nodes and expect the reconnect sheet. State plainly that neither has been exercised here.

- [ ] **Step 4: Tick the plan and append execution notes**

Change every `- [ ]` to `- [x]` and append `## Execution notes — <date>` listing the deviations ruled during execution, one line each.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs
git commit -m "docs: M3 shipped — .vv, TLS and migration; refresh CLAUDE.md"
```

---

## Self-review notes

- **Spec coverage (§3 + M3):** `.vv` INI with all six fields we consume (T1); TLS via Network.framework with the file's CA and `host-subject`, no OpenSSL (T2–T4); the failure sheet's expected/presented subjects (T3, T8); `MAIN_MIGRATE_BEGIN`/`MIGRATE_SWITCH_HOST` → the reconnect prompt with the new host prefilled (T6, T8); document type already registered, now wired to connect (T9); `delete-this-file` honoured with the existing preference (T9). Full channel switchover stays deferred, as the spec says.
- **Known gaps, by design:** no Proxmox cluster, so a real `.vv` and real migration messages are unverified — both are listed in "What cannot be verified", carried into `docs/dev-server.md`, and must be repeated in the final report. TLS *is* verified end-to-end against OpenSSL, including both negative cases.
- **Type consistency:** `VVFile(host:port:tlsPort:password:hostSubject:caPEM:title:deleteAfterConnecting:)`, `Certificates.parsePEM/subjectComponents/subjectDN/matches/parseSubject`, `TLSPolicy(caPEM:hostSubject:)` / `.verify(peerChain:)`, `TLSFailure.handshake/untrusted/badCertificate/subjectMismatch(expected:presented:)`, `ConnectFailureKind.hostSubjectMismatch(expected:presented:)`, `MigrationTarget(host:port:tlsPort:certSubject:)`, `SessionEvent.migrated`, `ConnectionConfig(host:port:tlsPort:password:hostSubject:caPEM:)` and `ConnectionConfig(vv:)`, `ConnectionTarget`, `SavedConnection.init(vv:name:)` — spelled the same in every task that uses them.
- **Ordering note:** Task 2 references `SpiceError.tls(TLSFailure)`, which Task 3 formally introduces. Whichever lands first must carry the `Kind` change; the task that follows then builds on it. Called out in Task 2's Step 4.
