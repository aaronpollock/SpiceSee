import os
import SpiceCanvas
import SpiceCore
import SpiceWire

public struct ConnectionConfig: Sendable {
    public var host: String, port: UInt16, password: String?
    public init(host: String, port: UInt16, password: String?) { self.host = host; self.port = port; self.password = password }
}

public enum PointerMode: Sendable, Equatable { case server, client }

/// Host input in guest terms. The app translates key codes with `KeyMap` before calling `send`.
public enum GuestInput: Sendable, Equatable {
    case keyDown(XTScancode), keyUp(XTScancode), releaseAllKeys
    case hostCapsLock(Bool)
    case pointerPosition(x: UInt32, y: UInt32, displayID: UInt8)
    case pointerMotion(dx: Int32, dy: Int32)
    case buttonDown(MouseButton), buttonUp(MouseButton)
    /// Positive = up (button 4), negative = down (button 5); one press/release pair per click.
    case wheel(clicks: Int)
}

public enum SessionEvent: Sendable {
    case connected(SessionInfo)
    case canvas(CanvasEvent)
    case pointerMode(PointerMode)
    case cursor(CursorChange, displayID: UInt8)
    case agent(connected: Bool)
    case channelFailed(ChannelDescriptor, SpiceError)
    case disconnected(SpiceError?)
}

public actor SpiceSession {
    /// Injectable transport factory so tests replay recordings; production uses NWTransport.
    public typealias TransportFactory = @Sendable (ChannelDescriptor) async throws -> any Transport

    public nonisolated let info: SessionInfo
    public nonisolated let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    private let inputStream: AsyncStream<GuestInput>
    private let inputCont: AsyncStream<GuestInput>.Continuation
    private let main: MainChannel
    private let canvas = Canvas()
    private var displays: [DisplayChannel] = []
    private var cursors: [CursorChannel] = []
    private var inputs: InputsChannel?
    private var tasks: [Task<Void, Never>] = []
    public private(set) var pointerMode: PointerMode
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
        pointerMode = info.mainInit.currentMouseMode == SpiceMouseMode.client ? .client : .server
        (events, cont) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        (inputStream, inputCont) = AsyncStream.makeStream(of: GuestInput.self, bufferingPolicy: .unbounded)
    }

    /// Queues host input for the guest. Synchronous and ordered: an `AsyncStream` continuation is
    /// the FIFO, so a key-up can never overtake its key-down the way independent `Task`s could.
    /// Input sent before the inputs channel is up, or after it failed, is dropped.
    public nonisolated func send(_ input: GuestInput) { inputCont.yield(input) }

    private func start(password: String?, transports: @escaping TransportFactory) async {
        cont.yield(.connected(info))
        cont.yield(.pointerMode(pointerMode))
        let canvasPump = Task { [canvas, cont] in for await e in canvas.events { cont.yield(.canvas(e)) } }
        tasks.append(canvasPump)

        var displayPumps: [Task<Void, Never>] = []
        var cursorPumps: [Task<Void, Never>] = []
        for desc in info.channels {
            do {
                switch desc.type {
                case .display:
                    let d = try await DisplayChannel.open(transport: try await transports(desc), connectionID: info.connectionID, id: desc.id, password: password)
                    displays.append(d)
                    let pump = Task { [canvas] in for await m in d.messages { await canvas.apply(m) } }
                    displayPumps.append(pump); tasks.append(pump)
                case .cursor:
                    let c = try await CursorChannel.open(transport: try await transports(desc), connectionID: info.connectionID, id: desc.id, password: password)
                    cursors.append(c)
                    let pump = Task { [cont] in
                        var tracker = CursorTracker()
                        for await m in c.messages { for change in tracker.apply(m) { cont.yield(.cursor(change, displayID: desc.id)) } }
                    }
                    cursorPumps.append(pump); tasks.append(pump)
                case .inputs where desc.id == 0:
                    inputs = try await InputsChannel.open(transport: try await transports(desc), connectionID: info.connectionID, password: password)
                default:
                    continue
                }
            } catch let e as SpiceError {
                cont.yield(.channelFailed(desc, e))
            } catch {
                cont.yield(.channelFailed(desc, SpiceError(.connect, channel: desc, underlying: String(describing: error))))
            }
        }

        // Nothing will ever drain the queue without a pump, so finish the continuation instead of
        // letting `send` grow an unbounded buffer: a `yield` on a finished stream is a no-op drop.
        if let inputs {
            let stream = inputStream
            tasks.append(Task { [weak self] in
                for await e in stream {
                    guard let self else { return }
                    do { try await self.dispatch(e, to: inputs) }
                    catch {
                        self.log.error("inputs send failed: \(String(describing: error))")
                        self.inputCont.finish()
                        return
                    }
                }
            })
        } else {
            inputCont.finish()
        }

        await negotiateMouseMode(supported: info.mainInit.supportedMouseModes)

        // `.disconnected` must come after every pixel and every cursor change, or a consumer that
        // stops on it (the app, and the replay test) loses the tail of the session. Main ending only
        // means the connection is gone; the other channels may still hold buffered messages, and the
        // canvas may still hold events those produced. Drain in that order, then close.
        tasks.append(Task { [weak self, main, canvas, cont] in
            for await m in main.events { await self?.handleMain(m) }
            for pump in displayPumps { _ = await pump.value }
            for pump in cursorPumps { _ = await pump.value }
            await canvas.finish()
            _ = await canvasPump.value
            cont.yield(.disconnected(nil))
        })
    }

    private func handleMain(_ m: MainMessage) async {
        switch m {
        case let .mouseMode(mode):
            let next: PointerMode = mode.current == SpiceMouseMode.client ? .client : .server
            if next != pointerMode { pointerMode = next; cont.yield(.pointerMode(next)) }
            await negotiateMouseMode(supported: mode.supported)
        case .agentConnected, .agentConnectedTokens: cont.yield(.agent(connected: true))
        case .agentDisconnected: cont.yield(.agent(connected: false))
        default: break
        }
    }

    /// Absolute positioning is what the user wants whenever the server can do it (agent or tablet);
    /// the server answers with MAIN_MOUSE_MODE, which `handleMain` turns into `.pointerMode`.
    private func negotiateMouseMode(supported: UInt32) async {
        guard supported & SpiceMouseMode.client != 0, pointerMode != .client else { return }
        do { try await main.requestMouseMode(SpiceMouseMode.client) }
        catch { log.error("mouse mode request failed: \(String(describing: error))") }
    }

    private func dispatch(_ e: GuestInput, to ch: InputsChannel) async throws {
        switch e {
        case let .keyDown(s): try await ch.keyDown(s)
        case let .keyUp(s): try await ch.keyUp(s)
        case .releaseAllKeys: try await ch.releaseAllKeys()
        case let .hostCapsLock(on): try await ch.syncCapsLock(on)
        case let .pointerPosition(x, y, id): try await ch.mousePosition(x: x, y: y, displayID: id)
        case let .pointerMotion(dx, dy): try await ch.mouseMotion(dx: dx, dy: dy)
        case let .buttonDown(b): try await ch.buttonDown(b)
        case let .buttonUp(b): try await ch.buttonUp(b)
        case let .wheel(clicks):
            let button: MouseButton = clicks > 0 ? .up : .down
            for _ in 0 ..< abs(clicks) { try await ch.buttonDown(button); try await ch.buttonUp(button) }
        }
    }

    public func snapshotPrimary() async -> DecodedImage? {
        guard let id = await canvas.primarySurfaceID else { return nil }
        return await canvas.snapshot(surfaceID: id)
    }

    public func disconnect() {
        tasks.forEach { $0.cancel() }
        inputCont.finish()
        displays.forEach { d in Task { await d.close() } }
        cursors.forEach { c in Task { await c.close() } }
        if let inputs { Task { await inputs.close() } }
        Task { [main] in await main.close() }
        cont.yield(.disconnected(nil)); cont.finish()
    }
}
