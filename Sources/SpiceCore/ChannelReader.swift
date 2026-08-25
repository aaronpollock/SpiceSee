import Foundation
import os
import SpiceWire

public struct RawMessage: Sendable, Equatable {
    public var type: UInt16
    public var payload: [UInt8]
    public init(type: UInt16, payload: [UInt8]) { self.type = type; self.payload = payload }
}

public actor ChannelReader {
    public static let maxMessageSize = 64 << 20

    private let source: any ByteSource
    private let sink: any ByteSink
    private let miniHeader: Bool
    private let channel: ChannelDescriptor
    private let log = Logger(subsystem: "com.spicesee", category: "channel")
    private let continuation: AsyncStream<RawMessage>.Continuation
    public nonisolated let messages: AsyncStream<RawMessage>

    private var serial: UInt64 = 1
    private var ackWindow: UInt32 = 0
    private var sinceAck: UInt32 = 0
    public private(set) var lastRTTMillis: Double?

    public init(source: any ByteSource, sink: any ByteSink, miniHeader: Bool, channel: ChannelDescriptor) {
        self.source = source; self.sink = sink; self.miniHeader = miniHeader; self.channel = channel
        (messages, continuation) = AsyncStream.makeStream(of: RawMessage.self)
    }

    public func send(type: UInt16, payload: [UInt8]) async throws {
        try await sink.write(ClientMessage.frame(type: type, payload: payload, mini: miniHeader, serial: serial))
        serial += 1
    }

    public func run() async {
        defer { continuation.finish() }
        do {
            // Runs until the transport throws — closing it is how a channel is ended. Checking
            // `Task.isCancelled` here instead would drop a message the transport already holds
            // when the cancel lands first; cancellation only classifies the log line below.
            while true {
                let header = try await readHeader()
                guard header.size <= Self.maxMessageSize else {
                    log.error("\(self.channel.type.rawValue)/\(self.channel.id): message size \(header.size) exceeds limit")
                    return
                }
                let payload = try await source.read(exactly: Int(header.size))
                // Every message the server sends counts against its ack window, including the ones
                // consumed below — counting only what we forward drifts by one per ping until the
                // window is exhausted and the server stops sending on this channel.
                if ackWindow > 0 {
                    sinceAck += 1
                    if sinceAck >= ackWindow { sinceAck = 0; try await send(type: CommonClientMsg.ack.rawValue, payload: ClientMessage.ack()) }
                }
                if try await handleCommon(type: header.type, payload: payload) { continue }
                continuation.yield(RawMessage(type: header.type, payload: payload))
            }
        } catch where Task.isCancelled {
            log.info("\(self.channel.type.rawValue)/\(self.channel.id): closed: \(String(describing: error), privacy: .public)")
        } catch {
            // Not our doing: the server dropped this channel. `.info` is not persisted by the
            // unified log, which is how a silently frozen display went unexplained.
            log.error("\(self.channel.type.rawValue)/\(self.channel.id): connection lost: \(String(describing: error), privacy: .public)")
        }
    }

    private func readHeader() async throws -> DataHeader {
        if miniHeader {
            var r = SpiceReader(try await source.read(exactly: DataHeader.miniSize)); return try DataHeader(mini: &r)
        } else {
            var r = SpiceReader(try await source.read(exactly: DataHeader.fullSize)); return try DataHeader(full: &r)
        }
    }

    /// Returns true if the message was consumed here.
    private func handleCommon(type: UInt16, payload: [UInt8]) async throws -> Bool {
        var r = SpiceReader(payload)
        switch CommonServerMsg(rawValue: type) {
        case .setAck:
            let a = try SetAck(reader: &r)
            ackWindow = a.window; sinceAck = 0
            try await send(type: CommonClientMsg.ackSync.rawValue, payload: ClientMessage.ackSync(generation: a.generation))
            return true
        case .ping:
            let p = try Ping(reader: &r)
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            if p.timestamp > 0, now > p.timestamp { lastRTTMillis = Double(now - p.timestamp) / 1000 }
            try await send(type: CommonClientMsg.pong.rawValue, payload: ClientMessage.pong(p))
            return true
        case .notify:
            let n = try Notify(reader: &r)
            log.notice("server notify (\(n.severity)): \(n.message)")
            return true
        case .disconnecting:
            log.notice("server disconnecting")
            return false
        default:
            return false
        }
    }
}
