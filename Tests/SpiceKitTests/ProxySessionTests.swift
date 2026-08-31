import Foundation
import Network
import Security
import Testing
import SpiceCore
import SpiceWire
@testable import SpiceKit

/// Link reply + MAIN_INIT + an empty channels list: the least a server can say for
/// `SpiceSession.connect` to succeed without spawning any further channels.
private func cannedServer() throws -> [UInt8] {
    var err: Unmanaged<CFError>?
    guard let priv = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                            kSecAttrKeySizeInBits as String: 1024] as CFDictionary, &err),
          let pub = SecKeyCopyPublicKey(priv),
          let pkcs1 = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
        throw SpiceError(.auth, underlying: "keygen")
    }
    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(0)
    let start = w.bytes.count
    w.u32(0); w.bytes(Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1)))
    w.u32(1); w.u32(0); w.u32(178)
    w.u32(1 << CommonCap.miniHeader | 1 << CommonCap.authSpice)
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    w.u32(0)                                                       // link result
    var mi = SpiceWriter(); [7, 1, 3, 2, 0, 10, 0, 0].forEach { mi.u32(UInt32($0)) }
    w.bytes(ClientMessage.frame(type: MainServerMsg.`init`.rawValue, payload: mi.bytes, mini: true, serial: 0))
    var cl = SpiceWriter(); cl.u32(0)
    w.bytes(ClientMessage.frame(type: MainServerMsg.channelsList.rawValue, payload: cl.bytes, mini: true, serial: 0))
    return w.bytes
}

/// A CONNECT proxy that answers 200 and plays the canned server the way a real one is timed:
/// the payload goes out only after the client's first post-tunnel bytes (the link header)
/// arrive. Sending it with — or straight after — the 200 can coalesce both into one TCP
/// segment, and Network.framework's CONNECT parser discards tunnel bytes that share a segment
/// with the header. A real proxy can never do that: the server only speaks after the client
/// does, a round-trip after the 200.
private func startProxy(serving bytes: [UInt8], heads: AsyncStream<String>.Continuation) throws -> NWListener {
    let listener = try NWListener(using: .tcp)
    let queue = DispatchQueue(label: "test.vv-proxy")
    listener.newConnectionHandler = { conn in
        conn.start(queue: queue)
        readHead(conn, sofar: Data()) { head in
            heads.yield(head)
            conn.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8),
                      completion: .contentProcessed { _ in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    guard data != nil, error == nil else { return }
                    conn.send(content: Data(bytes), completion: .contentProcessed { _ in drain(conn) })
                }
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

private func drain(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
        if data != nil, error == nil { drain(conn) }
    }
}

@Test func configCarriesTheVVProxy() throws {
    let vv = try VVFile.parse("[virt-viewer]\nhost=pvespiceproxy:aa:1:n::bb\ntls-port=61000\nproxy=http://p.example:3128")
    #expect(ConnectionConfig(vv: vv).proxy == HTTPConnectProxy(host: "p.example", port: 3128))
}

/// The whole `.vv` path in one piece: `SpiceSession.connect(config)` must route through the
/// file's proxy and hand it the host token verbatim — this is the line the missing-proxy bug
/// lived on.
@Test func sessionConnectsThroughTheConfigProxy() async throws {
    let token = "pvespiceproxy:6a95fbc4:114:pve1::35f9bc"
    let (heads, headCont) = AsyncStream.makeStream(of: String.self)
    let listener = try startProxy(serving: try cannedServer(), heads: headCont)
    defer { listener.cancel() }
    var port: UInt16 = 0
    for _ in 0..<100 where port == 0 {
        port = listener.port?.rawValue ?? 0
        if port == 0 { try await Task.sleep(for: .milliseconds(10)) }
    }

    let session = try await SpiceSession.connect(ConnectionConfig(
        host: token, port: 61000, proxy: HTTPConnectProxy(host: "127.0.0.1", port: port)))
    await session.disconnect()

    var iterator = heads.makeAsyncIterator()
    let head = try #require(await iterator.next())
    #expect(head.hasPrefix("CONNECT \(token):61000 HTTP/1.1\r\n"))
}
