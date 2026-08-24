import os
import SpiceWire

public actor DisplayChannel {
    public nonisolated let messages: AsyncStream<DisplayMessage>
    private let reader: ChannelReader
    private let loop: Task<Void, Never>
    private let pump: Task<Void, Never>

    public static func clientCaps() -> CapabilitySet {
        CapabilitySet(bits: [DisplayCap.sizedStream, DisplayCap.monitorsConfig, DisplayCap.streamReport,
                             DisplayCap.multiCodec, DisplayCap.codecMjpeg, DisplayCap.codecH264])
    }

    public static func open(transport: any Transport, connectionID: UInt32, id: UInt8, password: String?) async throws -> DisplayChannel {
        let desc = ChannelDescriptor(type: .display, id: id)
        let link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: desc,
                                                   channelCaps: clientCaps(), password: password)
        let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: desc)
        let loop = Task { await reader.run() }
        try await reader.send(type: DisplayClientMsg.`init`.rawValue,
                              payload: ClientMessage.displayInit(cacheSize: 40 << 20, glzWindowSize: 16 << 20))
        return DisplayChannel(reader: reader, loop: loop, descriptor: desc)
    }

    private init(reader: ChannelReader, loop: Task<Void, Never>, descriptor: ChannelDescriptor) {
        self.reader = reader; self.loop = loop
        let (stream, cont) = AsyncStream.makeStream(of: DisplayMessage.self, bufferingPolicy: .unbounded)
        messages = stream
        let log = Logger(subsystem: "com.spicesee", category: "display")
        let source = reader.messages
        pump = Task {
            for await raw in source {
                do { cont.yield(try DisplayMessage(type: raw.type, payload: raw.payload)) }
                catch { log.error("display/\(descriptor.id): drop type \(raw.type): \(String(describing: error))") }
            }
            cont.finish()
        }
    }

    public func close() { pump.cancel(); loop.cancel() }
}
