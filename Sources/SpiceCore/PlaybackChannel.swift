import os
import SpiceWire

/// The playback channel: link, then a pump that parses each frame into a `PlaybackMessage`.
/// `caps` is the caller's: the Opus bit depends on a decoder probe that belongs to SpiceMedia.
public actor PlaybackChannel {
    public nonisolated let messages: AsyncStream<PlaybackMessage>
    private let reader: ChannelReader
    private let transport: any Transport
    private let loop: Task<Void, Never>
    private let pump: Task<Void, Never>

    public static func open(transport: any Transport, connectionID: UInt32, id: UInt8, password: String?,
                            caps: CapabilitySet) async throws -> PlaybackChannel {
        let desc = ChannelDescriptor(type: .playback, id: id)
        do {
            let link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: desc,
                                                       channelCaps: caps, password: password)
            let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: desc)
            let loop = Task { await reader.run(); await transport.close() }
            return PlaybackChannel(reader: reader, transport: transport, loop: loop, descriptor: desc)
        } catch {
            await transport.close()
            throw error
        }
    }

    private init(reader: ChannelReader, transport: any Transport, loop: Task<Void, Never>, descriptor: ChannelDescriptor) {
        self.reader = reader; self.transport = transport; self.loop = loop
        let (stream, cont) = AsyncStream.makeStream(of: PlaybackMessage.self, bufferingPolicy: .unbounded)
        messages = stream
        let log = Logger(subsystem: "com.spicesee", category: "playback")
        let source = reader.messages
        pump = Task {
            for await raw in source {
                do { cont.yield(try PlaybackMessage(type: raw.type, payload: raw.payload)) }
                catch { log.error("playback/\(descriptor.id): drop type \(raw.type): \(String(describing: error), privacy: .public)") }
            }
            cont.finish()
        }
    }

    public func close() async { loop.cancel(); await transport.close() }
}
