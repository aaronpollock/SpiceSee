import os
import SpiceWire

public actor CursorChannel {
    public nonisolated let messages: AsyncStream<CursorMessage>
    private let reader: ChannelReader
    private let loop: Task<Void, Never>
    private let pump: Task<Void, Never>

    public static func open(transport: any Transport, connectionID: UInt32, id: UInt8, password: String?) async throws -> CursorChannel {
        let desc = ChannelDescriptor(type: .cursor, id: id)
        let link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: desc,
                                                   channelCaps: CapabilitySet(), password: password)
        let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: desc)
        let loop = Task { await reader.run() }
        return CursorChannel(reader: reader, loop: loop, descriptor: desc)
    }

    private init(reader: ChannelReader, loop: Task<Void, Never>, descriptor: ChannelDescriptor) {
        self.reader = reader; self.loop = loop
        let (stream, cont) = AsyncStream.makeStream(of: CursorMessage.self, bufferingPolicy: .unbounded)
        messages = stream
        let log = Logger(subsystem: "com.spicesee", category: "cursor")
        let source = reader.messages
        pump = Task {
            for await raw in source {
                do { cont.yield(try CursorMessage(type: raw.type, payload: raw.payload)) }
                catch { log.error("cursor/\(descriptor.id): drop type \(raw.type): \(String(describing: error))") }
            }
            cont.finish()
        }
    }

    public func close() { pump.cancel(); loop.cancel() }
}
