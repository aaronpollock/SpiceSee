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
/// `SpiceKitBackend` drives this with the real engine; `MockSessionBackend` still backs `--mock`, so
/// every screen stays reviewable without a server. Landing the engine needed no view changes — if one
/// ever seems to, the seam is wrong and the fix belongs in the adapter.
protocol SessionBackend: Sendable {
    func connect(host: String, port: UInt16, tlsPort: UInt16?, password: String?) -> AsyncStream<BackendEvent>
    func disconnect() async
    func sendCtrlAltDel() async
}
