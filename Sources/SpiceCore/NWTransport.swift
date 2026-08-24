import Foundation
import Network

public actor NWTransport: Transport {
    private let connection: NWConnection

    private init(connection: NWConnection) { self.connection = connection }

    public static func connect(host: String, port: UInt16) async throws -> NWTransport {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw SpiceError(.connect, underlying: "bad port") }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
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
        c.stateUpdateHandler = nil
        return NWTransport(connection: c)
    }

    public func read(exactly n: Int) async throws -> [UInt8] {
        if n == 0 { return [] }
        return try await withCheckedThrowingContinuation { k in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let error { k.resume(throwing: SpiceError(.closed, underlying: error.localizedDescription)); return }
                guard let data, data.count == n else { k.resume(throwing: SpiceError(.closed, underlying: isComplete ? "EOF" : "short read")); return }
                k.resume(returning: [UInt8](data))
            }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { k.resume(throwing: SpiceError(.closed, underlying: error.localizedDescription)) } else { k.resume() }
            })
        }
    }

    public func close() { connection.cancel() }
}
