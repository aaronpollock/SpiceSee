import Foundation
import SpiceCanvas
import SpiceCore
import SpiceKit
import SpiceWire

func usage() -> Never {
    print("""
    usage: spicesee-cli connect <host> <port> [password] [--tls-port <p>] [--ca <file.pem>] [--host-subject <s>]
           spicesee-cli dump <host> <port> <seconds> <out.png> [password]
           spicesee-cli vv <file.vv> [seconds out.png]
    """)
    exit(2)
}

/// Pulls `--name value` pairs out of the argument list, leaving the positional arguments in order.
func takeFlags(_ args: [String], _ names: Set<String>) -> ([String], [String: String]) {
    var positional: [String] = [], flags: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if names.contains(a) {
            guard i + 1 < args.count else { usage() }
            flags[a] = args[i + 1]; i += 2
        } else if a.hasPrefix("--") {
            usage()
        } else {
            positional.append(a); i += 1
        }
    }
    return (positional, flags)
}

/// The engine's raw `SpiceError` is deliberately terse; the CLI is the one place that has to make it
/// readable, and a wrong CA has to be distinguishable from a wrong host-subject at a glance.
func describe(_ error: Error) -> String {
    guard let e = error as? SpiceError else { return String(describing: error) }
    switch e.kind {
    case let .tls(.subjectMismatch(expected, presented)):
        return """
        TLS: the server's certificate subject is not the one host-subject asks for
          expected:  \(expected)
          presented: \(presented)
        """
    case let .tls(.untrusted(reason)):
        return "TLS: the server's certificate is not trusted by the file's CA — \(reason)"
    case let .tls(.badCertificate(reason)): return "TLS: \(reason)"
    case let .tls(.handshake(reason)): return "TLS: handshake failed — \(reason)"
    case .auth, .link(.permissionDenied):
        return "the server refused the ticket (a .vv ticket expires in about 30 seconds — reopen the console and retry)"
    case .connect: return "could not connect" + (e.underlying.map { ": \($0)" } ?? "")
    case let .vvFile(reason): return "not a usable .vv file: \(reason)"
    default: return String(describing: e)
    }
}

func printMainInit(host: String, port: UInt16, tls: TLSPolicy?, password: String?) async throws {
    let t = try await NWTransport.connect(host: host, port: port, tls: tls)
    let main = try await MainChannel.open(transport: t, password: password)
    let info = await main.info
    print("MAIN_INIT session=\(info.mainInit.sessionID) mouse=\(info.mainInit.currentMouseMode) agent=\(info.mainInit.agentConnected) tokens=\(info.mainInit.agentTokens) mmtime=\(info.mainInit.multiMediaTime)")
    print("channels: \(info.channels.map { "\($0.type)/\($0.id)" }.joined(separator: " "))")
}

func capture(_ config: ConnectionConfig, seconds: Double, out: URL) async throws {
    let session = try await SpiceSession.connect(config)
    print("connected: \(session.info.channels.count) channels; capturing for \(seconds)s")
    try await Task.sleep(for: .seconds(seconds))
    guard let frame = await session.snapshotPrimary() else {
        print("error: no primary surface — the guest sent no display data"); exit(1)
    }
    try PNG.encode(frame).write(to: out)
    await session.disconnect()
    print("wrote \(frame.width)x\(frame.height) to \(out.path)")
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }

// Top-level `await`, not Task + semaphore: top-level code is @MainActor, so a Task there cannot
// run while the main thread is blocked waiting on it.
switch args[1] {
case "connect":
    let (positional, flags) = takeFlags(Array(args.dropFirst(2)), ["--tls-port", "--ca", "--host-subject"])
    guard positional.count >= 2, let port = UInt16(positional[1]) else { usage() }
    let host = positional[0]
    let password = positional.count > 2 ? positional[2] : nil
    do {
        var tlsPort: UInt16?
        if let raw = flags["--tls-port"] {
            guard let p = UInt16(raw) else { usage() }
            tlsPort = p
        } else if flags["--ca"] != nil || flags["--host-subject"] != nil {
            // Silently ignoring a CA on a plain-TCP connection would look like it was honoured.
            print("error: --ca and --host-subject need --tls-port"); exit(2)
        }
        // --ca takes a file so a certificate never sits in shell history or a process list.
        let caPEM = try flags["--ca"].map { try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) }
        let policy = tlsPort != nil ? try TLSPolicy(caPEM: caPEM, hostSubject: flags["--host-subject"], host: host) : nil
        try await printMainInit(host: host, port: tlsPort ?? port, tls: policy, password: password)
    } catch {
        print("error: \(describe(error))"); exit(1)
    }

case "dump":
    let host = args[2]
    guard args.count >= 6, let port = UInt16(args[3]), let seconds = Double(args[4]) else { usage() }
    let out = URL(fileURLWithPath: args[5])
    let password = args.count > 6 ? args[6] : nil
    do {
        try await capture(ConnectionConfig(host: host, port: port, password: password), seconds: seconds, out: out)
    } catch {
        print("error: \(describe(error))"); exit(1)
    }

case "vv":
    guard args.count == 3 || args.count == 5 else { usage() }
    do {
        let vv = try VVFile.parse(contentsOf: URL(fileURLWithPath: args[2]))
        let config = ConnectionConfig(vv: vv)
        // The password is a one-shot ticket; it is never printed, not even elided per-character.
        print("""
        \(vv.title.map { "title: \($0)\n" } ?? "")\
        host=\(vv.host) port=\(vv.port.map(String.init) ?? "none") tls-port=\(vv.tlsPort.map(String.init) ?? "none") \
        ca=\(vv.caPEM == nil ? "no" : "yes") host-subject=\(vv.hostSubject ?? "none") \
        password=\(vv.password == nil ? "none" : "present") tls=\(config.usesTLS)
        """)
        if args.count == 5 {
            guard let seconds = Double(args[3]) else { usage() }
            try await capture(config, seconds: seconds, out: URL(fileURLWithPath: args[4]))
        } else {
            guard let port = config.tlsPort ?? config.port else {
                print("error: the file names no port"); exit(1)
            }
            let policy = config.usesTLS ? try TLSPolicy(caPEM: config.caPEM, hostSubject: config.hostSubject, host: config.host) : nil
            try await printMainInit(host: config.host, port: port, tls: policy, password: config.password)
        }
    } catch {
        print("error: \(describe(error))"); exit(1)
    }

default:
    usage()
}
