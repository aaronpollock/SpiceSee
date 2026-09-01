import Foundation
import SpiceCanvas
import SpiceCore
import SpiceKit
import SpiceWire

func usage() -> Never {
    print("""
    usage: spicesee-cli connect <host> <port> [password] [--tls-port <p>] [--ca <file.pem>] [--host-subject <s>]
           spicesee-cli dump <host> <port> <seconds> <out.png> [password]
           spicesee-cli clipboard <host> <port> [password] [--send <text>] [--send-image <png>] [--save-image <out.png>] [--seconds <n>]
           spicesee-cli resize <host> <port> <width> <height> [password] [--seconds <n>]
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

/// Line endings are the whole point of half the clipboard code, so they must be visible in the
/// output rather than reflowing it.
func escaped(_ s: String) -> String {
    s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
}

/// Exercises the agent clipboard against a real guest: prints the negotiation, answers the guest's
/// paste requests with `text`, and fetches whatever the guest copies. This is how M5 is checked
/// end to end — the unit tests can only prove the bytes, not that a real vdagent accepts them.
func clipboardProbe(_ config: ConnectionConfig, seconds: Double, send text: String?,
                     sendImage: [UInt8]?, saveImageTo: URL?) async throws {
    let session = try await SpiceSession.connect(config)
    print("connected; watching the clipboard for \(seconds)s")
    let deadline = Task {
        try? await Task.sleep(for: .seconds(seconds))
        await session.disconnect()
    }
    defer { deadline.cancel() }

    for await event in session.events {
        switch event {
        case let .agent(connected):
            print("agent \(connected ? "connected" : "gone")")
        case let .clipboard(.available(on)):
            print("clipboard sharing \(on ? "negotiated" : "unavailable")")
            if on {
                var offered: [ClipboardType] = []
                if let text {
                    print("offering \(text.utf8.count) bytes of text")
                    offered.append(.utf8Text)
                }
                if sendImage != nil { offered.append(.imagePNG) }
                if !offered.isEmpty { await session.offerClipboard(offered) }
            }
        case let .clipboard(.guestOffers(types)):
            print("guest grabbed, offering: \(types.map(String.init(describing:)).joined(separator: " "))")
            if types.contains(.utf8Text) { await session.requestClipboard(.utf8Text) }
            if types.contains(.imagePNG), saveImageTo != nil { await session.requestClipboard(.imagePNG) }
        case let .clipboard(.guestRequests(type)):
            print("guest is pasting, wants \(type)")
            if type == .imagePNG {
                guard let sendImage else { print("  nothing to send (pass --send-image)"); continue }
                await session.sendClipboard(.imagePNG, sendImage)
                print("  sent \(sendImage.count) bytes")
                continue
            }
            guard let text else { print("  nothing to send (pass --send)"); continue }
            await session.sendClipboard(.utf8Text, Array(text.utf8))
            print("  sent \(text.utf8.count) bytes")
        case let .clipboard(.guestData(.imagePNG, bytes)):
            guard let saveImageTo else { continue }
            try Data(bytes).write(to: saveImageTo)
            print("wrote \(bytes.count) bytes to \(saveImageTo.path)")
        case let .clipboard(.guestData(type, bytes)):
            print("guest sent \(bytes.count) bytes of \(type): \"\(escaped(String(decoding: bytes, as: UTF8.self)))\"")
        case .clipboard(.guestReleased):
            print("guest released its clipboard")
        case .disconnected:
            print("disconnected")
            return
        default:
            break
        }
    }
}

/// Asks a live guest to change resolution and reports what comes back. Proves the whole wire path
/// — capability gate, packed message, guest reaction — without dragging a window.
func resizeProbe(_ config: ConnectionConfig, width: UInt32, height: UInt32, seconds: Double) async throws {
    let session = try await SpiceSession.connect(config)
    print("connected; requesting \(width)x\(height), watching for \(seconds)s")
    let deadline = Task {
        try? await Task.sleep(for: .seconds(seconds))
        await session.disconnect()
    }
    defer { deadline.cancel() }

    for await event in session.events {
        switch event {
        case let .agent(connected):
            print("agent \(connected ? "connected" : "gone")")
        case .clipboard(.available):
            // Capability negotiation is complete once clipboard availability is decided —
            // the same ANNOUNCE_CAPABILITIES answers for monitors config.
            await session.sendMonitorsConfig([AgentMonitorConfig(width: width, height: height)])
            print("sent VD_AGENT_MONITORS_CONFIG \(width)x\(height) (dropped silently if the guest lacks the cap)")
        case let .monitorsConfig(heads, displayID: id):
            print("display \(id) heads: \(heads.map { "\($0.width)x\($0.height)@\($0.x),\($0.y)" }.joined(separator: " "))")
        case let .canvas(.surfaceCreated(d), displayID: id) where d.isPrimary:
            print("display \(id) primary now \(d.width)x\(d.height)")
        case .disconnected:
            print("disconnected")
            return
        default:
            break
        }
    }
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

case "clipboard":
    let (positional, flags) = takeFlags(Array(args.dropFirst(2)), ["--send", "--send-image", "--save-image", "--seconds"])
    guard positional.count >= 2, let port = UInt16(positional[1]) else { usage() }
    let seconds = flags["--seconds"].flatMap(Double.init) ?? 20
    do {
        // Read up front so a missing file fails fast with a readable error, not mid-negotiation.
        let sendImage = try flags["--send-image"].map { try Array(Data(contentsOf: URL(fileURLWithPath: $0))) }
        let saveImageTo = flags["--save-image"].map { URL(fileURLWithPath: $0) }
        try await clipboardProbe(ConnectionConfig(host: positional[0], port: port,
                                                  password: positional.count > 2 ? positional[2] : nil),
                                 seconds: seconds, send: flags["--send"],
                                 sendImage: sendImage, saveImageTo: saveImageTo)
    } catch {
        print("error: \(describe(error))"); exit(1)
    }

case "resize":
    let (positional, flags) = takeFlags(Array(args.dropFirst(2)), ["--seconds"])
    guard positional.count >= 4, let port = UInt16(positional[1]),
          let width = UInt32(positional[2]), let height = UInt32(positional[3]) else { usage() }
    let seconds = flags["--seconds"].flatMap(Double.init) ?? 20
    do {
        try await resizeProbe(ConnectionConfig(host: positional[0], port: port,
                                               password: positional.count > 4 ? positional[4] : nil),
                              width: width, height: height, seconds: seconds)
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
