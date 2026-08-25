import os
import SpiceWire

public struct SessionInfo: Sendable {
    public var connectionID: UInt32
    public var mainInit: MainInit
    public var channels: [ChannelDescriptor]
}

public actor MainChannel {
    public static let descriptor = ChannelDescriptor(type: .main, id: 0)
    public let info: SessionInfo
    public nonisolated let events: AsyncStream<MainMessage>
    private let reader: ChannelReader
    private let transport: any Transport
    private let loop: Task<Void, Never>
    private let pump: Task<Void, Never>
    private let log = Logger(subsystem: "com.spicesee", category: "main")

    public static func open(transport: any Transport, password: String?) async throws -> MainChannel {
        do {
            let link = try await LinkHandshake.perform(on: transport, connectionID: 0, channel: descriptor,
                                                       channelCaps: CapabilitySet(), password: password)
            let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: descriptor)
            let loop = Task { await reader.run(); await transport.close() }
            var iterator = reader.messages.makeAsyncIterator()

            func next() async throws -> MainMessage {
                guard let raw = await iterator.next() else { throw SpiceError(.closed, channel: descriptor) }
                do { return try MainMessage(type: raw.type, payload: raw.payload) }
                catch let e as WireError { throw SpiceError(.protocolError(e), channel: descriptor) }
            }

            guard case let .`init`(mainInit) = try await next() else { throw SpiceError(.protocolError(.unsupported("expected MAIN_INIT")), channel: descriptor) }
            try await reader.send(type: MainClientMsg.attachChannels.rawValue, payload: ClientMessage.attachChannels())

            var channels: [ChannelDescriptor] = []
            var pending: [MainMessage] = []
            while true {
                let m = try await next()
                if case let .channelsList(l) = m { channels = l.channels; break }
                pending.append(m)
            }
            let info = SessionInfo(connectionID: mainInit.sessionID, mainInit: mainInit, channels: channels)
            return MainChannel(info: info, reader: reader, transport: transport, loop: loop, pending: pending)
        } catch {
            await transport.close()
            throw error
        }
    }

    /// The pump resumes the (unicast) message stream where `open` left off — a fresh iterator
    /// shares the stream's buffer, and the iterator itself cannot cross into a Sendable closure.
    private init(info: SessionInfo, reader: ChannelReader, transport: any Transport, loop: Task<Void, Never>, pending: [MainMessage]) {
        self.info = info
        self.reader = reader
        self.transport = transport
        self.loop = loop
        let (stream, cont) = AsyncStream.makeStream(of: MainMessage.self)
        events = stream
        let messages = reader.messages
        pump = Task {
            pending.forEach { cont.yield($0) }
            for await raw in messages {
                if let m = try? MainMessage(type: raw.type, payload: raw.payload) { cont.yield(m) }
            }
            cont.finish()
        }
    }

    public func requestMouseMode(_ mode: UInt32) async throws {
        try await reader.send(type: MainClientMsg.mouseModeRequest.rawValue, payload: ClientMessage.mouseModeRequest(mode))
    }

    /// Opens the agent stream. `tokens` is what the *server* may spend on us; spice-gtk sends `~0`,
    /// which is how a client says it will not throttle the guest.
    public func startAgent(tokens: UInt32 = .max) async throws {
        try await reader.send(type: MainClientMsg.agentStart.rawValue, payload: ClientMessage.agentStart(tokens: tokens))
    }

    /// One `MAIN_AGENT_DATA`; the caller has already cut the message into token-sized chunks.
    public func sendAgentData(_ chunk: [UInt8]) async throws {
        try await reader.send(type: MainClientMsg.agentData.rawValue, payload: chunk)
    }

    public func close() async { loop.cancel(); await transport.close() }
}
