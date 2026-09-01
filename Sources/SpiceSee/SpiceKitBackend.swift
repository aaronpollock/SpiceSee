import Foundation
import os
import SpiceCanvas
import SpiceCore
import SpiceKit
import SpiceMedia
import SpiceWire

/// The real engine behind `SessionBackend`, replacing `MockSessionBackend` outside `--mock`.
///
/// Everything the UI needs is mapped here — no view knows that SPICE exists. If a view ever needs
/// editing to accommodate the engine, the seam is wrong and the fix belongs in this file.
final class SpiceKitBackend: SessionBackend {
    private let live = LiveSession()
    private let log = Logger(subsystem: "com.spicesee", category: "backend")

    /// One FIFO for the backend's lifetime: `sendInput` yields into it synchronously and a single
    /// consumer — started in `init` and never cancelled — drains it, so the guest sees events in the
    /// order the views produced them. There is exactly one consumer because two would race: the
    /// stdlib hands each element to whichever is waiting, so a connect task still unwinding could
    /// swallow the next session's `.begin` and leave the live session silent. The sentinels therefore
    /// carry the session they delimit: `.end` only clears the current session if it is that session.
    /// Input queued before `.begin` or after `.end` is dropped, not replayed into the next guest,
    /// because there is no current session to send it to. The bounded buffer only caps memory.
    /// `.layout` carries a `ViewportMapper` snapshot into the FIFO so the input consumer can
    /// translate pointer positions without touching shared mutable state — the same "stamped, not
    /// queried" rule the codebase applies to `AgentEvent`.
    private enum Queued: Sendable { case begin(SpiceSession), end(SpiceSession), host(InputEvent), guest(GuestInput), layout(ViewportMapper) }
    private let inputCont: AsyncStream<Queued>.Continuation

    init() {
        let (inputs, continuation) = AsyncStream.makeStream(of: Queued.self, bufferingPolicy: .bufferingNewest(1024))
        inputCont = continuation
        Task {
            var current: SpiceSession?
            var mapper = ViewportMapper()
            for await q in inputs {
                switch q {
                case let .begin(s): current = s
                case let .end(s): if current === s { current = nil }
                case let .host(e): if let s = current { Self.translate(e, mapper: mapper).forEach(s.send) }
                case let .guest(g): current?.send(g)
                case let .layout(m): mapper = m
                }
            }
        }
    }

    func sendInput(_ event: InputEvent) { inputCont.yield(.host(event)) }

    func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> {
        let endpoint = target.endpoint
        let live = live, log = log
        return AsyncStream { continuation in
            let task = Task {
                let session: SpiceSession
                do {
                    session = try await SpiceSession.connect(ConnectionConfig(
                        host: target.host, port: target.port, tlsPort: target.tlsPort,
                        password: target.password, hostSubject: target.hostSubject, caPEM: target.caPEM,
                        proxy: try target.proxy.map { try HTTPConnectProxy(parsing: $0) }))
                } catch let error as SpiceError {
                    log.error("connect failed: \(String(describing: error))")
                    continuation.yield(.failed(Self.failure(for: error, endpoint: endpoint)))
                    continuation.finish()
                    return
                } catch {
                    log.error("connect failed: \(String(describing: error))")
                    continuation.yield(.failed(.other(title: "The connection failed",
                                                      message: "SpiceSee could not open a session with \(endpoint).")))
                    continuation.finish()
                    return
                }
                // A Cancel during the handshake cannot interrupt `SpiceSession.connect`, so a session
                // that arrives after the task was cancelled is stale: close it instead of storing it.
                if Task.isCancelled {
                    await session.disconnect()
                    continuation.finish()
                    return
                }
                // `connect` returning means the handshake and the host-subject verify both passed —
                // but only a TLS connection did either, so a plain-TCP session never claims the step.
                if target.usesTLS { continuation.yield(.step(.tls)) }
                await live.store(session)

                inputCont.yield(.begin(session))
                defer { inputCont.yield(.end(session)) }

                continuation.yield(.step(.ticket))
                continuation.yield(.step(.channels))
                continuation.yield(.agent(session.info.mainInit.agentConnected != 0 ? .connected : .absent))

                var mapper = ViewportMapper()
                var announced = false

                func viewportInfos() -> [ViewportInfo] {
                    let layouts = mapper.layouts
                    return layouts.enumerated().map { i, l in
                        ViewportInfo(id: l.viewportID, index: i, total: layouts.count,
                                     width: l.rect.width, height: l.rect.height)
                    }
                }
                func publishLayout() {
                    let infos = viewportInfos()
                    // An empty layout is a primary being rebuilt, not a real one: installing it in
                    // the input FIFO would drop every pointer position until the primary returns.
                    guard !infos.isEmpty else { return }
                    inputCont.yield(.layout(mapper))
                    if announced { continuation.yield(.viewportsChanged(infos)) }
                    else { continuation.yield(.connected(viewports: infos)); announced = true }
                }

                for await event in session.events {
                    switch event {
                    case .connected:
                        break   // the UI is told once there are pixels to show, below
                    case let .canvas(.surfaceCreated(d), displayID: id) where d.isPrimary:
                        // Gate `.connected` on the primary surface: before it exists there is
                        // nothing to put in a viewport, and ViewportInfo carries its size.
                        mapper.primaryCreated(displayID: id, width: d.width, height: d.height)
                        publishLayout()
                    case let .canvas(.surfaceDestroyed(sid), displayID: id):
                        // Only the primary is a viewport; the mapper only tracks primaries, and a
                        // destroyed primary must NOT re-announce an empty list — the guest is about
                        // to recreate it at a new size (the resize path), so hold the windows.
                        if sid == 0 { mapper.primaryDestroyed(displayID: id) }
                    case let .monitorsConfig(heads, displayID: id):
                        mapper.headsChanged(displayID: id, heads: heads)
                        publishLayout()
                    case let .canvas(.updated(u), displayID: id) where u.isPrimary:
                        for s in mapper.slices(displayID: id, dirtyX: Int(u.rect.left), dirtyY: Int(u.rect.top),
                                               width: Int(u.rect.width), height: Int(u.rect.height)) {
                            let whole = s.width == Int(u.rect.width) && s.height == Int(u.rect.height)
                            continuation.yield(.frame(FrameUpdate(
                                viewportID: s.viewportID,
                                surfaceWidth: s.headWidth, surfaceHeight: s.headHeight,
                                x: s.destX, y: s.destY, width: s.width, height: s.height,
                                pixels: whole ? u.pixels : ViewportMapper.extract(
                                    u.pixels, rowPixels: Int(u.rect.width),
                                    x: s.srcX, y: s.srcY, width: s.width, height: s.height))))
                        }
                    case .canvas(.updated, displayID: _), .canvas(.surfaceCreated, displayID: _):
                        break   // off-screen surfaces are scratch buffers, not viewport content
                    case let .canvas(.unsupported(what), displayID: _):
                        log.notice("canvas: \(what, privacy: .public)")
                    case let .pointerMode(mode):
                        continuation.yield(.pointerMode(mode == .client ? .client : .server))
                    case let .cursor(change, displayID):
                        switch change {
                        case .shape:
                            for l in mapper.layouts where l.displayID == displayID {
                                continuation.yield(.cursor(viewportID: l.viewportID, Self.translate(change)))
                            }
                        case let .moved(x, y):
                            // Only the head under the pointer: broadcasting would draw a ghost in the
                            // letterbox of every other head's window.
                            if let l = mapper.layout(displayID: displayID, containingX: x, y: y) {
                                continuation.yield(.cursor(viewportID: l.viewportID,
                                                           .moved(x: x - l.rect.x, y: y - l.rect.y)))
                            }
                        }
                    case let .agent(connected):
                        continuation.yield(.agent(connected ? .connected : .absent))
                    case let .clipboard(event):
                        if let mapped = Self.translate(event) { continuation.yield(.clipboard(mapped)) }
                    case let .streamFrame(f, displayID: id):
                        for l in mapper.layouts(displayID: id, intersectingX: Int(f.dest.left), y: Int(f.dest.top),
                                                width: Int(f.dest.width), height: Int(f.dest.height)) {
                            var u = Self.translate(f, viewportID: l.viewportID)
                            u.dest.x -= l.rect.x; u.dest.y -= l.rect.y
                            u.clip = u.clip.map { $0.map { r in
                                var r = r; r.x -= l.rect.x; r.y -= l.rect.y; return r } }
                            continuation.yield(.streamFrame(u))
                        }
                    case let .streamDestroyed(id: sid, displayID: id):
                        for l in mapper.layouts where l.displayID == id {
                            continuation.yield(.streamDestroyed(viewportID: l.viewportID, streamID: sid))
                        }
                    case let .allStreamsDestroyed(displayID: id):
                        for l in mapper.layouts where l.displayID == id {
                            continuation.yield(.streamDestroyed(viewportID: l.viewportID, streamID: nil))
                        }
                    case let .migrated(t):
                        // The adapter only knows the host it dialled; SessionModel substitutes the
                        // connection's display name, which is what the sheet actually quotes.
                        continuation.yield(.migrated(MigrationOffer(vmName: target.host,
                                                                    newHost: t.host,
                                                                    newPort: t.port ?? 0,
                                                                    newTLSPort: t.tlsPort,
                                                                    certSubject: t.certSubject)))
                    case let .channelFailed(desc, error):
                        // A failed secondary channel degrades the session; only main is fatal.
                        if desc.type == .main {
                            log.error("main channel failed: \(String(describing: error))")
                            continuation.yield(.failed(Self.failure(for: error, endpoint: endpoint)))
                        } else {
                            log.error("\(String(describing: desc.type))/\(desc.id) failed, continuing: \(String(describing: error))")
                        }
                    case let .disconnected(error):
                        if let error, !announced {
                            continuation.yield(.failed(Self.failure(for: error, endpoint: endpoint)))
                        } else {
                            continuation.yield(.disconnected)
                        }
                        continuation.finish()
                        return
                    case .audio: break   // wired in Task 7
                    }
                }
                continuation.yield(.disconnected)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func disconnect() async { await live.disconnect() }

    func offerClipboard(_ kinds: [ClipboardKind]) async {
        await live.session?.offerClipboard(kinds.map(Self.wireType))
    }

    func requestClipboard(_ kind: ClipboardKind) async {
        await live.session?.requestClipboard(Self.wireType(kind))
    }

    func sendClipboardText(_ text: String) async {
        await live.session?.sendClipboard(.utf8Text, Array(text.utf8))
    }

    func sendClipboardPNG(_ bytes: [UInt8]) async {
        await live.session?.sendClipboard(.imagePNG, bytes)
    }

    private static func wireType(_ k: ClipboardKind) -> ClipboardType { k == .text ? .utf8Text : .imagePNG }
    private static func kind(_ t: ClipboardType) -> ClipboardKind? {
        switch t {
        case .utf8Text: .text
        case .imagePNG: .png
        default: nil
        }
    }

    func requestDisplayLayout(_ layouts: [DisplayLayout]) async {
        let ordered = layouts.sorted { $0.viewportID < $1.viewportID }
        await live.session?.sendMonitorsConfig(MonitorTiling.compose(
            ordered.map { (width: $0.width, height: $0.height, enabled: $0.enabled) }))
    }

    /// Types the seam does not speak (BMP, TIFF, file lists) are dropped here: announcing an offer
    /// the app cannot answer would strand the guest waiting.
    private static func translate(_ e: SpiceKit.ClipboardEvent) -> ClipboardEvent? {
        switch e {
        case let .available(on): return .available(on)
        case let .guestOffers(types):
            let kinds = types.compactMap(kind)
            return kinds.isEmpty ? nil : .guestOffers(kinds)
        case let .guestRequests(type): return kind(type).map(ClipboardEvent.guestRequests)
        case let .guestData(type, bytes):
            switch type {
            case .utf8Text: return .guestText(String(decoding: bytes, as: UTF8.self))
            case .imagePNG: return .guestImagePNG(bytes)
            default: return nil
            }
        case .guestReleased: return .guestReleased
        }
    }

    /// The guest's secure attention sequence: LCtrl, LAlt, Delete down, then up in reverse.
    func sendCtrlAltDel() async {
        for s in [XTScancode.leftControl, .leftAlt, .delete] { inputCont.yield(.guest(.keyDown(s))) }
        for s in [XTScancode.delete, .leftAlt, .leftControl] { inputCont.yield(.guest(.keyUp(s))) }
    }

    /// Internal rather than private so the head-origin arithmetic is pinned by `InputTranslationTests`.
    static func translate(_ e: InputEvent, mapper: ViewportMapper) -> [GuestInput] {
        switch e {
        case let .keyDown(code, m):
            return KeyMap.scancode(keyCode: code, commandMapsTo: target(m.commandMapsTo), optionMapsTo: target(m.optionMapsTo)).map { [.keyDown($0)] } ?? []
        case let .keyUp(code, m):
            return KeyMap.scancode(keyCode: code, commandMapsTo: target(m.commandMapsTo), optionMapsTo: target(m.optionMapsTo)).map { [.keyUp($0)] } ?? []
        case let .capsLock(on): return [.hostCapsLock(on)]
        case .releaseAllKeys: return [.releaseAllKeys]
        case let .pointerPosition(x, y, id):
            guard let o = mapper.origin(of: id) else { return [] }
            return [.pointerPosition(x: UInt32(max(0, x + o.x)), y: UInt32(max(0, y + o.y)),
                                     displayID: o.displayID)]
        case let .pointerMotion(dx, dy): return [.pointerMotion(dx: Int32(clamping: dx), dy: Int32(clamping: dy))]
        case let .buttonDown(b): return [.buttonDown(button(b))]
        case let .buttonUp(b): return [.buttonUp(button(b))]
        case let .wheel(clicks): return clicks == 0 ? [] : [.wheel(clicks: clicks)]
        }
    }

    static func translate(_ f: SpiceMedia.StreamFrame, viewportID: Int) -> StreamFrameUpdate {
        let clip: [GuestRect]?
        switch f.clip {
        case .none: clip = nil
        case let .rects(rects): clip = rects.map(Self.guestRect)
        }
        return StreamFrameUpdate(viewportID: viewportID, streamID: f.streamID, dest: Self.guestRect(f.dest),
                                 clip: clip, width: f.width, height: f.height, pixels: f.pixels)
    }

    private static func guestRect(_ r: SpiceRect) -> GuestRect {
        GuestRect(x: Int(r.left), y: Int(r.top), width: Int(r.width), height: Int(r.height))
    }

    private static func target(_ m: GuestModifier) -> ModifierTarget { switch m { case .super: .super; case .ctrl: .ctrl; case .alt: .alt } }
    private static func button(_ b: PointerButton) -> MouseButton { switch b { case .left: .left; case .middle: .middle; case .right: .right } }
    private static func translate(_ c: SpiceCanvas.CursorChange) -> CursorChange {
        switch c {
        case let .shape(s): .shape(s.map { CursorImage(width: $0.width, height: $0.height, hotX: $0.hotX, hotY: $0.hotY, pixels: $0.pixels) })
        case let .moved(x, y): .moved(x: x, y: y)
        }
    }

    /// The category comes from `SpiceKit`, which is tested; the wording is the design's and stays here.
    private static func failure(for error: SpiceError, endpoint: String) -> ConnectFailure {
        switch ConnectFailureKind.of(error) {
        case .passwordRejected: .passwordRejected
        case .refused: .refused(endpoint: endpoint)
        case let .hostSubjectMismatch(expected, presented):
            .hostSubjectMismatch(expected: expected, presented: presented, host: endpoint)
        case .other: .other(title: "The connection failed",
                            message: "SpiceSee could not keep a session open with \(endpoint).")
        }
    }
}

/// Holds the live session so `disconnect()` can reach it without locks.
private actor LiveSession {
    private(set) var session: SpiceSession?
    func store(_ s: SpiceSession) { session = s }
    func disconnect() async {
        await session?.disconnect()
        session = nil
    }
}
