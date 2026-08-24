import Foundation
import SpiceCore
import SpiceWire

let args = CommandLine.arguments
guard args.count >= 4, args[1] == "connect", let port = UInt16(args[3]) else {
    print("usage: spicesee-cli connect <host> <port> [password]"); exit(2)
}
let password = args.count > 4 ? args[4] : nil

// Top-level `await`, not Task + semaphore: top-level code is @MainActor, so a Task there cannot
// run while the main thread is blocked waiting on it.
do {
    let t = try await NWTransport.connect(host: args[2], port: port)
    let main = try await MainChannel.open(transport: t, password: password)
    let info = await main.info
    print("MAIN_INIT session=\(info.mainInit.sessionID) mouse=\(info.mainInit.currentMouseMode) agent=\(info.mainInit.agentConnected) tokens=\(info.mainInit.agentTokens) mmtime=\(info.mainInit.multiMediaTime)")
    print("channels: \(info.channels.map { "\($0.type)/\($0.id)" }.joined(separator: " "))")
} catch {
    print("error: \(error)"); exit(1)
}
