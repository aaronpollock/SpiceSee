import os
import SpiceWire

public actor DisplayChannel {
    public nonisolated let messages: AsyncStream<DisplayMessage>
    private let reader: ChannelReader
    private let transport: any Transport
    private let loop: Task<Void, Never>
    private let pump: Task<Void, Never>

    public static func clientCaps() -> CapabilitySet {
        CapabilitySet(bits: [DisplayCap.sizedStream, DisplayCap.monitorsConfig, DisplayCap.streamReport,
                             DisplayCap.multiCodec, DisplayCap.codecMjpeg, DisplayCap.codecH264])
    }

    public static func open(transport: any Transport, connectionID: UInt32, id: UInt8, password: String?) async throws -> DisplayChannel {
        let desc = ChannelDescriptor(type: .display, id: id)
        do {
            let link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: desc,
                                                       channelCaps: clientCaps(), password: password)
            let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: desc)
            // The loop ending, for any reason, is the last use of the socket: close it, or the
            // server's FIN leaves it in CLOSE_WAIT for the life of the process.
            let loop = Task { await reader.run(); await transport.close() }
            try await reader.send(type: DisplayClientMsg.`init`.rawValue,
                                  payload: ClientMessage.displayInit(cacheSize: 40 << 20, glzWindowSize: 16 << 20))
            return DisplayChannel(reader: reader, transport: transport, loop: loop, descriptor: desc)
        } catch {
            await transport.close()
            throw error
        }
    }

    private init(reader: ChannelReader, transport: any Transport, loop: Task<Void, Never>, descriptor: ChannelDescriptor) {
        self.reader = reader; self.transport = transport; self.loop = loop
        let (stream, cont) = AsyncStream.makeStream(of: DisplayMessage.self, bufferingPolicy: .unbounded)
        messages = stream
        let log = Logger(subsystem: "com.spicesee", category: "display")
        let source = reader.messages
        pump = Task {
            for await raw in source {
                do { cont.yield(try DisplayMessage(type: raw.type, payload: raw.payload)) }
                catch {
                    // The reason and a payload prefix are deliberately public: a draw this
                    // channel cannot parse is the one situation where the bytes themselves
                    // are the diagnostic, and they never contain a ticket.
                    let prefix = raw.payload.prefix(96).map { String(format: "%02x", $0) }.joined()
                    log.error("display/\(descriptor.id): drop type \(raw.type) size \(raw.payload.count): \(String(describing: error), privacy: .public) payload[..96]=\(prefix, privacy: .public)")
                }
            }
            cont.finish()
        }
    }

    /// Only the socket is closed; the pump drains what the reader already received, so nothing
    /// the server sent before the close is lost.
    public func close() async { loop.cancel(); await transport.close() }

    public func send(streamReport r: StreamReport) async throws {
        try await reader.send(type: DisplayClientMsg.streamReport.rawValue, payload: ClientMessage.streamReport(r))
    }
}
