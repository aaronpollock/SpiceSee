import Foundation
import Network
import Testing
@testable import SpiceCore

/// A one-connection HTTP CONNECT proxy: yields the request head it received, answers with
/// `status`, then echoes every byte back. Real enough to prove the bytes on the wire are what
/// pveproxy would see — the Proxmox host token is full of colons, so the CONNECT target's exact
/// formatting is the thing under test, not an implementation detail.
private func startProxy(status: String, heads: AsyncStream<String>.Continuation) throws -> NWListener {
    let listener = try NWListener(using: .tcp)
    let queue = DispatchQueue(label: "test.connect-proxy")
    listener.newConnectionHandler = { conn in
        conn.start(queue: queue)
        readHead(conn, sofar: Data()) { head in
            heads.yield(head)
            conn.send(content: Data("HTTP/1.1 \(status)\r\n\r\n".utf8), completion: .contentProcessed { _ in
                if status.hasPrefix("200") { echo(conn) } else { conn.cancel() }
            })
        }
    }
    listener.start(queue: queue)
    return listener
}

private func readHead(_ conn: NWConnection, sofar: Data, done: @escaping @Sendable (String) -> Void) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        guard let data else { return }
        let head = sofar + data
        if let end = head.range(of: Data("\r\n\r\n".utf8)) {
            done(String(decoding: head[..<end.lowerBound], as: UTF8.self))
        } else {
            readHead(conn, sofar: head, done: done)
        }
    }
}

private func echo(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
        guard let data, error == nil else { return }
        conn.send(content: data, completion: .contentProcessed { _ in
            if !isComplete { echo(conn) }
        })
    }
}

private func readyPort(of listener: NWListener) async throws -> UInt16 {
    for _ in 0..<100 {
        if let port = listener.port?.rawValue, port != 0 { return port }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SpiceError(.connect, underlying: "listener never became ready")
}

/// The Proxmox flow: the dialled host is an opaque token, meaningful only to the proxy, and it
/// must arrive in the CONNECT target verbatim — unbracketed and unescaped — with the port
/// appended after one final colon.
@Test func connectsThroughAnHTTPConnectProxy() async throws {
    let token = "pvespiceproxy:6a95f870:114:pve1.example.com::ead7168f"
    let (heads, headCont) = AsyncStream.makeStream(of: String.self)
    let listener = try startProxy(status: "200 Connection established", heads: headCont)
    defer { listener.cancel() }
    let port = try await readyPort(of: listener)

    let transport = try await NWTransport.connect(host: token, port: 61000,
                                                  proxy: HTTPConnectProxy(host: "127.0.0.1", port: port))
    try await transport.write([0x52, 0x45, 0x44])
    #expect(try await transport.read(exactly: 3) == [0x52, 0x45, 0x44])
    await transport.close()

    var iterator = heads.makeAsyncIterator()
    let head = try #require(await iterator.next())
    #expect(head.hasPrefix("CONNECT \(token):61000 HTTP/1.1\r\n"))
}

@Test func proxyRefusalFailsTheConnect() async throws {
    let (_, headCont) = AsyncStream.makeStream(of: String.self)
    let listener = try startProxy(status: "403 Forbidden", heads: headCont)
    defer { listener.cancel() }
    let port = try await readyPort(of: listener)

    await #expect(throws: SpiceError.self) {
        _ = try await NWTransport.connect(host: "pvespiceproxy:aa:1:n::bb", port: 61000,
                                          proxy: HTTPConnectProxy(host: "127.0.0.1", port: port))
    }
}
