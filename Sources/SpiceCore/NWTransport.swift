import Foundation
import Network
import Security

public actor NWTransport: Transport {
    private let connection: NWConnection

    private init(connection: NWConnection) { self.connection = connection }

    public static func connect(host: String, port: UInt16, tls: TLSPolicy? = nil,
                               proxy: HTTPConnectProxy? = nil) async throws -> NWTransport {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw SpiceError(.connect, underlying: "bad port") }
        // The verify block can only answer yes/no, so the *reason* it said no has to reach the
        // continuation another way. A stream continuation is Sendable and its `yield` is synchronous:
        // the reason is buffered before `complete(false)` is called, and the connection cannot fail
        // before that, so the value is always in hand by the time the `catch` below reads it.
        let (rejections, rejected) = AsyncStream.makeStream(of: TLSFailure.self)
        let parameters: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
                guard let failure = tls.verify(peerChain: chain) else { complete(true); return }
                rejected.yield(failure)
                complete(false)
            }, DispatchQueue(label: "com.spicesee.tls"))
            parameters = NWParameters(tls: options, tcp: .init())
        } else {
            parameters = .tcp
        }

        // Proxmox consoles are reachable only through pveproxy: the dialled host is an opaque
        // token the proxy decodes, so it goes into the CONNECT target verbatim and never near DNS.
        if let proxy {
            guard let proxyPort = NWEndpoint.Port(rawValue: proxy.port) else {
                throw SpiceError(.connect, underlying: "bad proxy port")
            }
            let context = NWParameters.PrivacyContext(description: "com.spicesee.proxy")
            context.proxyConfigurations = [
                ProxyConfiguration(httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(proxy.host),
                                                               port: proxyPort), tlsOptions: nil)]
            parameters.setPrivacyContext(context)
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
            // the real reason, so prefer it. `finish` makes the read return nil instead of waiting
            // when the failure had nothing to do with trust.
            rejected.finish()
            var reasons = rejections.makeAsyncIterator()
            if let failure = await reasons.next() { throw SpiceError(.tls(failure)) }
            throw error
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
