import Foundation

/// One dirty-rect framebuffer update, in guest pixels.
struct FrameUpdate: Sendable {
    var viewportID: Int
    var surfaceWidth: Int
    var surfaceHeight: Int
    var x: Int, y: Int, width: Int, height: Int
    /// Tightly packed BGRA, `width * 4` bytes per row.
    var pixels: [UInt8]
}

/// Which side owns the pointer position. Client = absolute (`MOUSE_POSITION`, host cursor shows
/// the guest's shape); server = relative (`MOUSE_MOTION`, pointer captured while working).
enum PointerMode: Equatable, Sendable { case client, server }

enum PointerButton: Sendable { case left, middle, right }

struct KeyboardMapping: Equatable, Sendable {
    var commandMapsTo: GuestModifier = .super
    var optionMapsTo: GuestModifier = .alt
}

/// Host input in the host's own terms; the adapter translates key codes and coordinates.
enum InputEvent: Sendable {
    case keyDown(keyCode: UInt16, mapping: KeyboardMapping)
    case keyUp(keyCode: UInt16, mapping: KeyboardMapping)
    /// Host caps-lock state — on change and on focus — so the guest's lock keys follow the Mac's.
    case capsLock(on: Bool)
    case releaseAllKeys
    /// Client mode: absolute guest pixels.
    case pointerPosition(x: Int, y: Int, viewportID: Int)
    /// Server mode: raw deltas while captured.
    case pointerMotion(dx: Int, dy: Int)
    case buttonDown(PointerButton), buttonUp(PointerButton)
    /// Positive = up, negative = down.
    case wheel(clicks: Int)
}

/// BGRA, straight alpha, `width * 4` bytes per row; hotspot in cursor pixels.
struct CursorImage: Sendable, Equatable {
    var width: Int, height: Int, hotX: Int, hotY: Int
    var pixels: [UInt8]
}

enum CursorChange: Sendable, Equatable {
    case shape(CursorImage?)          // nil hides the pointer
    case moved(x: Int, y: Int)        // server mode only
}

/// What one viewport window consumes: pixels and the pointer drawn over them.
enum ViewportEvent: Sendable {
    case frame(FrameUpdate)
    case cursor(CursorChange)
}

enum BackendEvent: Sendable {
    case step(ConnectStep)
    case connected(viewports: [ViewportInfo])
    case agent(AgentState)
    case pointerMode(PointerMode)
    case frame(FrameUpdate)
    case cursor(viewportID: Int, CursorChange)
    case migrated(MigrationOffer)
    case failed(ConnectFailure)
    case disconnected
}

/// Everything needed to open one session. Grouped rather than passed as six arguments because a
/// `.vv` file supplies most of it at once.
struct ConnectionTarget: Sendable {
    var host: String
    var port: UInt16?
    var tlsPort: UInt16?
    var hostSubject: String?
    var caPEM: String?
    var password: String?

    /// "pve1.lan:61000" — the TLS port when there is one, matching `SavedConnection.endpoint`.
    var endpoint: String { "\(host):\(tlsPort ?? port ?? 0)" }
    var usesTLS: Bool { tlsPort != nil }
}

/// The seam between the UI and the SPICE engine.
///
/// `SpiceKitBackend` drives this with the real engine; `MockSessionBackend` still backs `--mock`, so
/// every screen stays reviewable without a server. Landing the engine needed no view changes — if one
/// ever seems to, the seam is wrong and the fix belongs in the adapter.
protocol SessionBackend: Sendable {
    func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent>
    func disconnect() async
    func sendCtrlAltDel() async
    /// Synchronous on purpose: the backend must preserve order, and a `Task` per event would not.
    func sendInput(_ event: InputEvent)
}
