import Testing
import SpiceKit
@testable import SpiceSee

/// Pointer positions arrive head-local from a viewport window and must leave surface-absolute,
/// stamped with the display channel the head belongs to.
@Suite struct InputTranslationTests {
    private var twoHeads: ViewportMapper {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 200, height: 100)
        m.headsChanged(displayID: 0, heads: [
            HeadRect(id: 0, x: 0, y: 0, width: 100, height: 100),
            HeadRect(id: 1, x: 100, y: 0, width: 100, height: 100),
        ])
        return m
    }

    @Test func pointerPositionGainsTheHeadOriginAndDisplayID() {
        let out = SpiceKitBackend.translate(.pointerPosition(x: 10, y: 20, viewportID: 1), mapper: twoHeads)
        #expect(out == [.pointerPosition(x: 110, y: 20, displayID: 0)])
    }

    @Test func pointerPositionForAnUnknownViewportIsDropped() {
        let out = SpiceKitBackend.translate(.pointerPosition(x: 10, y: 20, viewportID: 99), mapper: twoHeads)
        #expect(out.isEmpty)
    }

    @Test func pointerPositionBeforeAnyLayoutIsDropped() {
        let out = SpiceKitBackend.translate(.pointerPosition(x: 10, y: 20, viewportID: 0), mapper: ViewportMapper())
        #expect(out.isEmpty)
    }
}
