import Foundation
import Network

let args = CommandLine.arguments
guard args.count == 5, let listen = UInt16(args[1]), let upstreamPort = UInt16(args[3]) else {
    print("usage: spicerec <listen-port> <upstream-host> <upstream-port> <out-dir>"); exit(2)
}
let upstreamHost = args[2], outDir = args[4]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let queue = DispatchQueue(label: "spicerec")
// Only ever touched from `queue`, which is serial.
nonisolated(unsafe) var count = 0

@Sendable func pump(_ from: NWConnection, _ to: NWConnection, _ file: FileHandle) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
        if let data, !data.isEmpty {
            file.write(data)
            to.send(content: data, completion: .contentProcessed { _ in pump(from, to, file) })
        } else if done || error != nil {
            to.cancel(); file.closeFile()
        }
    }
}

let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: listen)!)
listener.newConnectionHandler = { client in
    count += 1
    let n = count
    let s2c = "\(outDir)/conn-\(n).s2c.bin", c2s = "\(outDir)/conn-\(n).c2s.bin"
    FileManager.default.createFile(atPath: s2c, contents: nil); FileManager.default.createFile(atPath: c2s, contents: nil)
    let server = NWConnection(host: NWEndpoint.Host(upstreamHost), port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
    server.stateUpdateHandler = { state in
        if case .ready = state {
            print("conn \(n): proxying")
            pump(client, server, FileHandle(forWritingAtPath: c2s)!)
            pump(server, client, FileHandle(forWritingAtPath: s2c)!)
        }
    }
    client.start(queue: queue); server.start(queue: queue)
}
listener.start(queue: queue)
print("spicerec listening on \(listen) -> \(upstreamHost):\(upstreamPort), writing \(outDir)")
dispatchMain()
