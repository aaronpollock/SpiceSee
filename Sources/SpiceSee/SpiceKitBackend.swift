import Foundation
import os
import SpiceCanvas
import SpiceCore
import SpiceKit
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
    private enum Queued: Sendable { case begin(SpiceSession), end(SpiceSession), host(InputEvent), guest(GuestInput) }
    private let inputCont: AsyncStream<Queued>.Continuation

    init() {
        let (inputs, continuation) = AsyncStream.makeStream(of: Queued.self, bufferingPolicy: .bufferingNewest(1024))
        inputCont = continuation
        Task {
            var current: SpiceSession?
            for await q in inputs {
                switch q {
                case let .begin(s): current = s
                case let .end(s): if current === s { current = nil }
                case let .host(e): if let s = current { Self.translate(e).forEach(s.send) }
                case let .guest(g): current?.send(g)
                }
            }
        }
    }

    func sendInput(_ event: InputEvent) { inputCont.yield(.host(event)) }

    func connect(host: String, port: UInt16, tlsPort: UInt16?, password: String?) -> AsyncStream<BackendEvent> {
        // tlsPort is honoured in M3, when the TLS verify block lands; M1 is plain TCP.
        let endpoint = "\(host):\(port)"
        let live = live, log = log
        return AsyncStream { continuation in
            let task = Task {
                let session: SpiceSession
                do {
                    session = try await SpiceSession.connect(ConnectionConfig(host: host, port: port, password: password))
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
                await live.store(session)

                inputCont.yield(.begin(session))
                defer { inputCont.yield(.end(session)) }

                let displays = session.info.channels.filter { $0.type == .display }
                // In M1 there is one display channel and one primary surface; M5 maps surfaces to
                // viewports properly for multi-monitor.
                let viewportID = displays.first.map { Int($0.id) } ?? 0
                continuation.yield(.step(.ticket))
                continuation.yield(.step(.channels))
                continuation.yield(.agent(session.info.mainInit.agentConnected != 0 ? .connected : .absent))

                var announced = false
                for await event in session.events {
                    switch event {
                    case .connected:
                        break   // the UI is told once there are pixels to show, below
                    case let .canvas(.surfaceCreated(d)) where d.isPrimary:
                        // Gate `.connected` on the primary surface: before it exists there is
                        // nothing to put in a viewport, and ViewportInfo carries its size.
                        let viewports = displays.enumerated().map { i, ch in
                            ViewportInfo(id: Int(ch.id), index: i, total: displays.count, width: d.width, height: d.height)
                        }
                        continuation.yield(.connected(viewports: viewports.isEmpty
                            ? [ViewportInfo(id: 0, index: 0, total: 1, width: d.width, height: d.height)]
                            : viewports))
                        announced = true
                    case let .canvas(.updated(u)) where u.isPrimary:
                        continuation.yield(.frame(FrameUpdate(viewportID: viewportID,
                                                              surfaceWidth: u.surfaceWidth, surfaceHeight: u.surfaceHeight,
                                                              x: Int(u.rect.left), y: Int(u.rect.top),
                                                              width: Int(u.rect.width), height: Int(u.rect.height),
                                                              pixels: u.pixels)))
                    case .canvas(.updated), .canvas(.surfaceCreated):
                        break   // off-screen surfaces are scratch buffers, not viewport content
                    case let .canvas(.unsupported(what)):
                        log.notice("canvas: \(what)")
                    case .canvas(.surfaceDestroyed):
                        break
                    case let .pointerMode(mode):
                        continuation.yield(.pointerMode(mode == .client ? .client : .server))
                    case let .cursor(change, displayID):
                        continuation.yield(.cursor(viewportID: Int(displayID), Self.translate(change)))
                    case let .agent(connected):
                        continuation.yield(.agent(connected ? .connected : .absent))
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
                    }
                }
                continuation.yield(.disconnected)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func disconnect() async { await live.disconnect() }

    /// The guest's secure attention sequence: LCtrl, LAlt, Delete down, then up in reverse.
    func sendCtrlAltDel() async {
        for s in [XTScancode.leftControl, .leftAlt, .delete] { inputCont.yield(.guest(.keyDown(s))) }
        for s in [XTScancode.delete, .leftAlt, .leftControl] { inputCont.yield(.guest(.keyUp(s))) }
    }

    private static func translate(_ e: InputEvent) -> [GuestInput] {
        switch e {
        case let .keyDown(code, m):
            return KeyMap.scancode(keyCode: code, commandMapsTo: target(m.commandMapsTo), optionMapsTo: target(m.optionMapsTo)).map { [.keyDown($0)] } ?? []
        case let .keyUp(code, m):
            return KeyMap.scancode(keyCode: code, commandMapsTo: target(m.commandMapsTo), optionMapsTo: target(m.optionMapsTo)).map { [.keyUp($0)] } ?? []
        case let .capsLock(on): return [.hostCapsLock(on)]
        case .releaseAllKeys: return [.releaseAllKeys]
        case let .pointerPosition(x, y, id): return [.pointerPosition(x: UInt32(max(0, x)), y: UInt32(max(0, y)), displayID: UInt8(clamping: id))]
        case let .pointerMotion(dx, dy): return [.pointerMotion(dx: Int32(clamping: dx), dy: Int32(clamping: dy))]
        case let .buttonDown(b): return [.buttonDown(button(b))]
        case let .buttonUp(b): return [.buttonUp(button(b))]
        case let .wheel(clicks): return clicks == 0 ? [] : [.wheel(clicks: clicks)]
        }
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
    private var session: SpiceSession?
    func store(_ s: SpiceSession) { session = s }
    func disconnect() async {
        await session?.disconnect()
        session = nil
    }
}
