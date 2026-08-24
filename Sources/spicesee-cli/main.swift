import Foundation
import SpiceCanvas
import SpiceCore
import SpiceKit
import SpiceWire

// usage: spicesee-cli connect <host> <port> [password]
//        spicesee-cli dump <host> <port> <seconds> <out.png> [password]
func usage() -> Never {
    print("""
    usage: spicesee-cli connect <host> <port> [password]
           spicesee-cli dump <host> <port> <seconds> <out.png> [password]
    """)
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 4, let port = UInt16(args[3]) else { usage() }
let host = args[2]

// Top-level `await`, not Task + semaphore: top-level code is @MainActor, so a Task there cannot
// run while the main thread is blocked waiting on it.
switch args[1] {
case "connect":
    let password = args.count > 4 ? args[4] : nil
    do {
        let t = try await NWTransport.connect(host: host, port: port)
        let main = try await MainChannel.open(transport: t, password: password)
        let info = await main.info
        print("MAIN_INIT session=\(info.mainInit.sessionID) mouse=\(info.mainInit.currentMouseMode) agent=\(info.mainInit.agentConnected) tokens=\(info.mainInit.agentTokens) mmtime=\(info.mainInit.multiMediaTime)")
        print("channels: \(info.channels.map { "\($0.type)/\($0.id)" }.joined(separator: " "))")
    } catch {
        print("error: \(error)"); exit(1)
    }

case "dump":
    guard args.count >= 6, let seconds = Double(args[4]) else { usage() }
    let out = URL(fileURLWithPath: args[5])
    let password = args.count > 6 ? args[6] : nil
    do {
        let session = try await SpiceSession.connect(ConnectionConfig(host: host, port: port, password: password))
        print("connected: \(session.info.channels.count) channels; capturing for \(seconds)s")
        try await Task.sleep(for: .seconds(seconds))
        guard let frame = await session.snapshotPrimary() else {
            print("error: no primary surface — the guest sent no display data"); exit(1)
        }
        try PNG.encode(frame).write(to: out)
        await session.disconnect()
        print("wrote \(frame.width)x\(frame.height) to \(out.path)")
    } catch {
        print("error: \(error)"); exit(1)
    }

default:
    usage()
}
