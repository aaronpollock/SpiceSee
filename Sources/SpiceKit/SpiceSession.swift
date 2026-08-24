import os
import SpiceCanvas
import SpiceCore
import SpiceWire

public struct ConnectionConfig: Sendable {
    public var host: String, port: UInt16, password: String?
    public init(host: String, port: UInt16, password: String?) { self.host = host; self.port = port; self.password = password }
}

public enum SessionEvent: Sendable {
    case connected(SessionInfo)
    case canvas(CanvasEvent)
    case channelFailed(ChannelDescriptor, SpiceError)
    case disconnected(SpiceError?)
}

public actor SpiceSession {
    /// Injectable transport factory so tests replay recordings; production uses NWTransport.
    public typealias TransportFactory = @Sendable (ChannelDescriptor) async throws -> any Transport

    public nonisolated let info: SessionInfo
    public nonisolated let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    private let main: MainChannel
    private let canvas = Canvas()
    private var displays: [DisplayChannel] = []
    private var tasks: [Task<Void, Never>] = []
    private let log = Logger(subsystem: "com.spicesee", category: "session")

    public static func connect(_ config: ConnectionConfig) async throws -> SpiceSession {
        try await connect(password: config.password) { _ in try await NWTransport.connect(host: config.host, port: config.port) }
    }

    public static func connect(password: String?, transports: @escaping TransportFactory) async throws -> SpiceSession {
        let mainTransport = try await transports(MainChannel.descriptor)
        let main = try await MainChannel.open(transport: mainTransport, password: password)
        let session = SpiceSession(main: main, info: await main.info)
        await session.start(password: password, transports: transports)
        return session
    }

    private init(main: MainChannel, info: SessionInfo) {
        self.main = main
        self.info = info
        (events, cont) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
    }

    private func start(password: String?, transports: @escaping TransportFactory) async {
        cont.yield(.connected(info))
        let canvasPump = Task { [canvas, cont] in
            for await e in canvas.events { cont.yield(.canvas(e)) }
        }
        tasks.append(canvasPump)

        var displayPumps: [Task<Void, Never>] = []
        for desc in info.channels where desc.type == .display {
            do {
                let t = try await transports(desc)
                let d = try await DisplayChannel.open(transport: t, connectionID: info.connectionID, id: desc.id, password: password)
                displays.append(d)
                let pump = Task { [canvas] in for await m in d.messages { await canvas.apply(m) } }
                displayPumps.append(pump)
                tasks.append(pump)
            } catch let e as SpiceError {
                cont.yield(.channelFailed(desc, e))
            } catch {
                cont.yield(.channelFailed(desc, SpiceError(.connect, channel: desc, underlying: String(describing: error))))
            }
        }

        // `.disconnected` must come after every pixel, or a consumer that stops on it (the app, and
        // the replay test) loses the tail of the session. Main ending only means the connection is
        // gone; the display channels may still hold buffered messages, and the canvas may still hold
        // events those produced. Drain in that order, then close.
        tasks.append(Task { [main, canvas, cont] in
            for await _ in main.events {}          // main events are consumed in M2+ (mouse mode, agent)
            for pump in displayPumps { _ = await pump.value }
            await canvas.finish()
            _ = await canvasPump.value
            cont.yield(.disconnected(nil))
        })
    }

    public func snapshotPrimary() async -> DecodedImage? {
        guard let id = await canvas.primarySurfaceID else { return nil }
        return await canvas.snapshot(surfaceID: id)
    }

    public func disconnect() {
        tasks.forEach { $0.cancel() }
        displays.forEach { d in Task { await d.close() } }
        Task { [main] in await main.close() }
        cont.yield(.disconnected(nil)); cont.finish()
    }
}
