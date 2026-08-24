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
                await live.store(session)

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

    /// Needs the inputs channel, which lands in M2.
    func sendCtrlAltDel() async { log.notice("ctrl-alt-del ignored: the inputs channel arrives in M2") }

    /// The category comes from `SpiceKit`, which is tested; the wording is the design's and stays here.
    private static func failure(for error: SpiceError, endpoint: String) -> ConnectFailure {
        switch ConnectFailureKind.of(error) {
        case .passwordRejected: .passwordRejected
        case .refused: .refused(endpoint: endpoint)
        case .hostSubjectMismatch: .hostSubjectMismatch(expected: "", presented: "", host: endpoint)
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
