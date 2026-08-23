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

enum BackendEvent: Sendable {
    case step(ConnectStep)
    case connected(viewports: [ViewportInfo])
    case agent(AgentState)
    case frame(FrameUpdate)
    case migrated(MigrationOffer)
    case failed(ConnectFailure)
    case disconnected
}

/// The seam between the UI and the SPICE engine.
///
/// `SpiceKit` does not exist yet — it is built by the M0–M1 plan — so the UI is written against this
/// protocol and verified today with `MockSessionBackend`. `SpiceKitBackend` replaces the mock once
/// `SpiceSession` lands; no view changes when it does.
protocol SessionBackend: Sendable {
    func connect(host: String, port: UInt16, tlsPort: UInt16?, password: String?) -> AsyncStream<BackendEvent>
    func disconnect() async
    func sendCtrlAltDel() async
}
