import Testing
import SpiceWire
@testable import SpiceKit

@Suite struct ViewportMapperTests {
    @Test func headsComeFromPrimarySurfaceEntriesOnly() throws {
        var w = SpiceWriter()
        w.u16(3); w.u16(4)                                    // count, maxAllowed
        // head 0: primary, 1920x1080 at 0,0
        [0, 0, 1920, 1080, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        // head 1: on surface 5 — not a viewport
        [1, 5, 800, 600, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        // head 2: primary, zero area — dropped
        [2, 0, 0, 0, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        let msg = try DisplayMessage(type: DisplayServerMsg.monitorsConfig.rawValue, payload: w.bytes)
        guard case let .monitorsConfig(cfg) = msg else { Issue.record("expected monitorsConfig"); return }
        let heads = HeadRect.heads(from: cfg)
        #expect(heads == [HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080)])
    }
}
