import os
import SpiceCanvas
import SpiceCore
import SpiceMedia
import SpiceWire

public struct ConnectionConfig: Sendable {
    public var host: String
    public var port: UInt16?
    public var tlsPort: UInt16?
    public var password: String?
    public var hostSubject: String?
    public var caPEM: String?
    public var proxy: HTTPConnectProxy?

    public init(host: String, port: UInt16? = nil, tlsPort: UInt16? = nil, password: String? = nil,
                hostSubject: String? = nil, caPEM: String? = nil, proxy: HTTPConnectProxy? = nil) {
        self.host = host; self.port = port; self.tlsPort = tlsPort; self.password = password
        self.hostSubject = hostSubject; self.caPEM = caPEM; self.proxy = proxy
    }

    public init(vv: VVFile) {
        self.init(host: vv.host, port: vv.port, tlsPort: vv.tlsPort, password: vv.password,
                  hostSubject: vv.hostSubject, caPEM: vv.caPEM, proxy: vv.proxy)
    }

    /// TLS wins when the file offers both: a Proxmox `.vv` carries `tls-port` precisely because the
    /// console is meant to be encrypted.
    public var usesTLS: Bool { tlsPort != nil }
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

/// Clipboard sharing, in the "by demand" shape the agent protocol uses: whoever copies announces
/// the types it can produce, and the data crosses only when the other side actually pastes.
public enum ClipboardEvent: Sendable, Equatable {
    /// Whether the guest agent is up and has negotiated clipboard sharing.
    case available(Bool)
    /// The guest copied something and offers these types. Ask for one with `requestClipboard`.
    case guestOffers([ClipboardType])
    /// The guest is pasting and wants the host clipboard; answer with `sendClipboard`.
    case guestRequests(ClipboardType)
    /// The guest's answer to `requestClipboard`. Text arrives with LF endings and no terminator.
    case guestData(ClipboardType, [UInt8])
    /// The guest dropped ownership of its clipboard.
    case guestReleased
}

public enum SessionEvent: Sendable {
    case connected(SessionInfo)
    case canvas(CanvasEvent)
    case pointerMode(PointerMode)
    case cursor(CursorChange, displayID: UInt8)
    case agent(connected: Bool)
    case clipboard(ClipboardEvent)
    case channelFailed(ChannelDescriptor, SpiceError)
    case disconnected(SpiceError?)
    case migrated(MigrationTarget)
    case streamFrame(StreamFrame, displayID: UInt8)
    case streamDestroyed(id: UInt32, displayID: UInt8)
    case allStreamsDestroyed(displayID: UInt8)
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
    private var players: [StreamPlayer] = []
    private var inputs: InputsChannel?
    private var agent: AgentSession?
    private var tasks: [Task<Void, Never>] = []
    private var closing = false
    /// Set when a channel ended without `disconnect` being called; reported with `.disconnected`.
    private var lossReason: SpiceError?
    public private(set) var pointerMode: PointerMode
    private let log = Logger(subsystem: "com.spicesee", category: "session")

    /// Every channel dials the same port and the same policy, which is what spice-gtk does: the
    /// server hands out one TLS port for the whole session.
    public static func connect(_ config: ConnectionConfig) async throws -> SpiceSession {
        let policy = config.usesTLS ? try TLSPolicy(caPEM: config.caPEM, hostSubject: config.hostSubject, host: config.host) : nil
        guard let port = config.tlsPort ?? config.port else {
            throw SpiceError(.connect, underlying: "no port")
        }
        return try await connect(password: config.password) { _ in
            try await NWTransport.connect(host: config.host, port: port, tls: policy, proxy: config.proxy)
        }
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
                    let player = StreamPlayer()
                    await player.setMMTime(info.mainInit.multiMediaTime)
                    players.append(player)
                    let playerPump = Task { [cont, weak self] in
                        for await e in player.events {
                            switch e {
                            case let .frame(f): cont.yield(.streamFrame(f, displayID: desc.id))
                            case let .destroyed(id): cont.yield(.streamDestroyed(id: id, displayID: desc.id))
                            case .allDestroyed: cont.yield(.allStreamsDestroyed(displayID: desc.id))
                            case let .report(r): await self?.sendStreamReport(r, on: d)
                            }
                        }
                    }
                    tasks.append(playerPump)
                    let pump = Task { [canvas, weak self] in
                        for await m in d.messages {
                            switch m {
                            case let .streamCreate(c): await player.handle(create: c)
                            case let .streamData(data): await player.handle(data: data)
                            case let .streamClip(id, clip): await player.handle(clipChange: id, clip: clip)
                            case let .streamDestroy(id): await player.handle(destroy: id)
                            case .streamDestroyAll: await player.handleDestroyAll()
                            case let .streamActivateReport(a): await player.handle(activateReport: a)
                            default: await canvas.apply(m)
                            }
                        }
                        // `.disconnected` must come after every stream frame too: finish the
                        // player so its events stream ends, then await the pump that forwards
                        // them, before ending the channel — same ordering the canvas pump relies on.
                        await player.finish()
                        _ = await playerPump.value
                        await self?.channelEnded(desc)
                    }
                    displayPumps.append(pump); tasks.append(pump)
                case .cursor:
                    let c = try await CursorChannel.open(transport: try await transports(desc), connectionID: info.connectionID, id: desc.id, password: password)
                    cursors.append(c)
                    let pump = Task { [cont, weak self] in
                        var tracker = CursorTracker()
                        for await m in c.messages { for change in tracker.apply(m) { cont.yield(.cursor(change, displayID: desc.id)) } }
                        await self?.channelEnded(desc)
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
        await startAgent()

        // `.disconnected` must come after every pixel and every cursor change, or a consumer that
        // stops on it (the app, and the replay test) loses the tail of the session. Main ending only
        // means the connection is gone; the other channels may still hold buffered messages, and the
        // canvas may still hold events those produced. Drain in that order, then close. Main ends
        // either because the server dropped it or because `channelEnded` closed it on another
        // channel's behalf — the pumps below finish either way, since every channel is closed.
        tasks.append(Task { [weak self, main, canvas, cont] in
            for await m in main.events { await self?.handleMain(m) }
            await self?.channelEnded(MainChannel.descriptor)
            for pump in displayPumps { _ = await pump.value }
            for pump in cursorPumps { _ = await pump.value }
            await canvas.finish()
            _ = await canvasPump.value
            cont.yield(.disconnected(await self?.lossReason))
        })
    }

    /// A channel the server closed on its own ends the whole session: a display gone quiet while
    /// main still answers pings is a frozen picture, not a degraded session — spice-server drops
    /// just the display client on `flush_commands: flush timeout`, and virt-viewer disconnects on
    /// any channel error. Closing everything makes the drain above run and report the loss.
    private func channelEnded(_ desc: ChannelDescriptor) async {
        guard !closing else { return }
        lossReason = SpiceError(.closed, channel: desc, underlying: "the server closed the channel")
        log.error("\(String(describing: desc.type), privacy: .public)/\(desc.id) closed by the server; ending the session")
        await closeChannels()
    }

    /// A lost report only degrades the server's bitrate adaptation for this stream — never worth
    /// ending the session over.
    private func sendStreamReport(_ r: StreamReport, on d: DisplayChannel) async {
        do { try await d.send(streamReport: r) }
        catch { log.error("stream report send failed: \(String(describing: error))") }
    }

    private func closeChannels() async {
        guard !closing else { return }
        closing = true
        inputCont.finish()
        for d in displays { await d.close() }
        for c in cursors { await c.close() }
        await inputs?.close()
        await main.close()
    }

    private func handleMain(_ m: MainMessage) async {
        switch m {
        case let .mouseMode(mode):
            let next: PointerMode = mode.current == SpiceMouseMode.client ? .client : .server
            if next != pointerMode { pointerMode = next; cont.yield(.pointerMode(next)) }
            await negotiateMouseMode(supported: mode.supported)
        case .agentConnected:
            cont.yield(.agent(connected: true))
            await connectAgent()
        case let .agentConnectedTokens(n):
            cont.yield(.agent(connected: true))
            await agent?.setTokens(n)
            await connectAgent()
        case .agentDisconnected:
            cont.yield(.agent(connected: false))
            await agent?.agentDisconnected()
            cont.yield(.clipboard(.available(false)))
        case let .agentData(payload): await agent?.receive(payload)
        case let .agentToken(n): await agent?.credit(n)
        case let .multiMediaTime(t): for p in players { await p.setMMTime(t.time) }
        case let .migrateSwitchHost(target): cont.yield(.migrated(target))
        // A begin without a switch means the server is preparing a migration it may still cancel;
        // the design's prompt belongs on the switch, so log and wait.
        case let .migrateBegin(target): log.notice("migration announced to \(target.host, privacy: .public)")
        case .migrateCancel, .migrateEnd: break
        default: break
        }
    }

    // MARK: Agent and clipboard

    /// Builds the agent session and starts it if `MAIN_INIT` already reported an agent. The token
    /// allowance is seeded here whether or not one is connected, because that is where the server
    /// states it.
    private func startAgent() async {
        let session = AgentSession { [main] chunk in try await main.sendAgentData(chunk) }
        agent = session
        tasks.append(Task { [cont, weak self] in
            for await m in session.messages { await self?.handleAgent(m) }
            _ = cont
        })
        await session.setTokens(info.mainInit.agentTokens)
        if info.mainInit.agentConnected != 0 { await connectAgent() }
    }

    private func connectAgent() async {
        guard let agent else { return }
        do { try await main.startAgent() }
        catch {
            log.error("agent start failed: \(String(describing: error))")
            return
        }
        await agent.agentConnected()
    }

    private func handleAgent(_ e: AgentEvent) async {
        switch e.message {
        case .announceCapabilities:
            cont.yield(.clipboard(.available(e.clipboardReady)))
        case let .clipboardGrab(selection, types):
            guard selection == .clipboard else { return }
            cont.yield(.clipboard(.guestOffers(types)))
        case let .clipboardRequest(selection, type):
            guard selection == .clipboard else { return }
            cont.yield(.clipboard(.guestRequests(type)))
        case let .clipboard(selection, type, data):
            guard selection == .clipboard else { return }
            var payload = data
            if type == .utf8Text {
                payload = ClipboardText.trimmingTrailingNULs(payload)
                if e.guestWantsCRLF { payload = ClipboardText.toLF(payload) }
            }
            cont.yield(.clipboard(.guestData(type, payload)))
        case let .clipboardRelease(selection):
            guard selection == .clipboard else { return }
            cont.yield(.clipboard(.guestReleased))
        case .monitorsConfig:
            break
        case .other:
            break
        }
    }

    /// Tells the guest the host clipboard changed and what it can be had as. The guest asks for one
    /// of `types` when the user pastes, which arrives as `.guestRequests`.
    public func offerClipboard(_ types: [ClipboardType]) async {
        guard let agent, await agent.clipboardReady, !types.isEmpty else { return }
        await agent.send(.clipboardGrab(.clipboard, types))
    }

    /// Asks the guest for what it offered in `.guestOffers`; the answer arrives as `.guestData`.
    public func requestClipboard(_ type: ClipboardType) async {
        guard let agent, await agent.clipboardReady else { return }
        await agent.send(.clipboardRequest(.clipboard, type))
    }

    /// Answers a `.guestRequests`. Text is given in LF and converted to the guest's convention here.
    public func sendClipboard(_ type: ClipboardType, _ data: [UInt8]) async {
        guard let agent, await agent.clipboardReady else { return }
        var payload = data
        if type == .utf8Text, await agent.guestWantsCRLF { payload = ClipboardText.toCRLF(payload) }
        await agent.send(.clipboard(.clipboard, type, payload))
    }

    /// Gives up the host's claim on the guest's clipboard.
    public func releaseClipboard() async {
        guard let agent, await agent.clipboardReady else { return }
        await agent.send(.clipboardRelease(.clipboard))
    }

    /// Asks the guest to adopt this monitor layout (`VD_AGENT_MONITORS_CONFIG`). Silently absent
    /// without a guest that announced the capability, like every other agent feature. The guest
    /// answers with a new primary surface and/or DISPLAY_MONITORS_CONFIG, never with a reply here.
    public func sendMonitorsConfig(_ monitors: [AgentMonitorConfig]) async {
        guard let agent, await agent.guestSupportsMonitorsConfig, !monitors.isEmpty else { return }
        await agent.send(.monitorsConfig(flags: AgentMonitorsFlags.usePosition, monitors: monitors))
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

    public func disconnect() async {
        tasks.forEach { $0.cancel() }
        await closeChannels()
        cont.yield(.disconnected(nil)); cont.finish()
    }
}
