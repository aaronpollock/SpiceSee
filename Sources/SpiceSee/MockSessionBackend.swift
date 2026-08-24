import Foundation

/// Drives every UI state without a server: bring-up steps, a synthetic desktop, agent transitions.
/// Selected by `--mock` or when `SPICESEE_MOCK=1`, so the design can be reviewed before the engine lands.
final class MockSessionBackend: SessionBackend {
    enum Scenario: String {
        case desktop, noAgent, refused, badPassword, certMismatch, migrate
    }

    private let scenario: Scenario
    init(scenario: Scenario = .desktop) { self.scenario = scenario }

    func connect(host: String, port: UInt16, tlsPort: UInt16?, password: String?) -> AsyncStream<BackendEvent> {
        let scenario = self.scenario
        let endpoint = "\(host):\(tlsPort ?? port)"
        return AsyncStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    continuation.yield(.step(.tls))
                    if scenario == .certMismatch {
                        try await Task.sleep(for: .milliseconds(300))
                        continuation.yield(.failed(.hostSubjectMismatch(
                            expected: "CN=pve1,O=PVE Cluster Manager CA",
                            presented: "CN=pve3,O=PVE Cluster Manager CA",
                            host: endpoint)))
                        continuation.finish(); return
                    }
                    if scenario == .refused {
                        continuation.yield(.failed(.refused(endpoint: endpoint)))
                        continuation.finish(); return
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    if scenario == .badPassword {
                        continuation.yield(.failed(.passwordRejected))
                        continuation.finish(); return
                    }
                    continuation.yield(.step(.ticket))
                    try await Task.sleep(for: .milliseconds(500))
                    continuation.yield(.step(.channels))
                    try await Task.sleep(for: .milliseconds(400))

                    let size = (width: 1920, height: 1080)
                    continuation.yield(.connected(viewports: [
                        ViewportInfo(id: 0, index: 0, total: 2, width: size.width, height: size.height),
                        ViewportInfo(id: 1, index: 1, total: 2, width: 2560, height: 1440),
                    ]))
                    continuation.yield(.agent(scenario == .noAgent ? .absent : .negotiating))
                    continuation.yield(.pointerMode(scenario == .noAgent ? .server : .client))
                    continuation.yield(.frame(Self.desktop(width: size.width, height: size.height)))
                    continuation.yield(.cursor(viewportID: 0, .shape(Self.arrowCursor)))
                    continuation.yield(.cursor(viewportID: 0, .moved(x: 300, y: 260)))
                    if scenario != .noAgent {
                        try await Task.sleep(for: .milliseconds(900))
                        continuation.yield(.agent(.connected))
                        continuation.yield(.pointerMode(.client))
                    }
                    if scenario == .migrate {
                        try await Task.sleep(for: .seconds(3))
                        continuation.yield(.migrated(MigrationOffer(vmName: "win11-desk", newHost: "pve3.lan", newPort: 5904)))
                    }
                    // Blink a caret so the viewport is visibly live.
                    var on = true
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        continuation.yield(.frame(Self.caret(on: on, surface: size)))
                        on.toggle()
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func disconnect() async {}
    func sendCtrlAltDel() async {}
    func sendInput(_ event: InputEvent) {}

    /// A 12×20 black arrow with a white outline — enough to see the overlay in `--mock`.
    private static let arrowCursor: CursorImage = {
        let w = 12, h = 20
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            let span = min(y, w - 1)   // widening diagonal
            for x in 0 ... span {
                let i = (y * w + x) * 4
                let edge = x == 0 || x == span || y == h - 1
                px[i] = edge ? 255 : 0; px[i + 1] = edge ? 255 : 0; px[i + 2] = edge ? 255 : 0; px[i + 3] = 255
            }
        }
        return CursorImage(width: w, height: h, hotX: 0, hotY: 0, pixels: px)
    }()

    /// A flat desktop with a title bar band, so scaling and 1:1 are visibly different.
    private static func desktop(width: Int, height: Int) -> FrameUpdate {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            let band = y < 96
            let (b, g, r): (UInt8, UInt8, UInt8) = band ? (60, 42, 32) : (UInt8(70 + y * 40 / height), 52, 44)
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = 0xFF
            }
        }
        return FrameUpdate(viewportID: 0, surfaceWidth: width, surfaceHeight: height,
                           x: 0, y: 0, width: width, height: height, pixels: px)
    }

    private static func caret(on: Bool, surface: (width: Int, height: Int)) -> FrameUpdate {
        let (w, h) = (10, 20)
        let v: UInt8 = on ? 0xE0 : 0x30
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 0xFF
        }
        return FrameUpdate(viewportID: 0, surfaceWidth: surface.width, surfaceHeight: surface.height,
                           x: 120, y: 200, width: w, height: h, pixels: px)
    }
}
