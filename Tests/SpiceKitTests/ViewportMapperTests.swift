import Testing
import SpiceWire
@testable import SpiceKit

@Suite struct ViewportMapperTests {
    @Test func headsComeFromPrimarySurfaceEntriesOnly() throws {
        var w = SpiceWriter()
        w.u16(4); w.u16(4)                                    // count, maxAllowed
        // head 0: primary, 1920x1080 at 0,0
        [0, 0, 1920, 1080, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        // head 1: on surface 5 — not a viewport
        [1, 5, 800, 600, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        // head 2: primary, zero area — dropped
        [2, 0, 0, 0, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        // head 3: primary, 1280x800 offset to the right of head 0 — exercises non-zero x/y mapping
        [3, 0, 1280, 800, 1920, 0, 0].forEach { w.u32(UInt32($0)) }
        let msg = try DisplayMessage(type: DisplayServerMsg.monitorsConfig.rawValue, payload: w.bytes)
        guard case let .monitorsConfig(cfg) = msg else { Issue.record("expected monitorsConfig"); return }
        let heads = HeadRect.heads(from: cfg)
        #expect(heads == [
            HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080),
            HeadRect(id: 3, x: 1920, y: 0, width: 1280, height: 800),
        ])
    }

    @Test func aPrimaryWithNoHeadsIsOneFullViewport() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 1280, height: 800)
        #expect(m.layouts == [ViewportLayout(displayID: 0, headIndex: 0,
                                             rect: HeadRect(id: 0, x: 0, y: 0, width: 1280, height: 800))])
        #expect(m.layouts[0].viewportID == 0)
    }

    @Test func headsCarveThePrimaryAndClampToIt() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 3000, height: 1080)
        m.headsChanged(displayID: 0, heads: [
            HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080),
            HeadRect(id: 1, x: 1920, y: 0, width: 2000, height: 1080),   // overhangs; clamps to 1080 wide
            HeadRect(id: 2, x: 3000, y: 0, width: 100, height: 100),     // fully outside; dropped
        ])
        #expect(m.layouts.map(\.rect) == [
            HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080),
            HeadRect(id: 1, x: 1920, y: 0, width: 1080, height: 1080),
        ])
        #expect(m.layouts.map(\.viewportID) == [0, 1])
    }

    @Test func headsSurviveAPrimaryRebuildAtANewSize() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 1920, height: 1080)
        m.headsChanged(displayID: 0, heads: [HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080)])
        m.primaryDestroyed(displayID: 0)
        #expect(m.layouts.isEmpty)
        m.primaryCreated(displayID: 0, width: 1024, height: 768)
        #expect(m.layouts.map(\.rect) == [HeadRect(id: 0, x: 0, y: 0, width: 1024, height: 768)])
    }

    @Test func secondDisplayChannelIsItsOwnViewport() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 1920, height: 1080)
        m.primaryCreated(displayID: 1, width: 2560, height: 1440)
        #expect(m.layouts.count == 2)
        #expect(m.layouts[1].viewportID == 1 << 8)
    }

    @Test func dirtyRectsSlicePerHead() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 200, height: 100)
        m.headsChanged(displayID: 0, heads: [
            HeadRect(id: 0, x: 0, y: 0, width: 100, height: 100),
            HeadRect(id: 1, x: 100, y: 0, width: 100, height: 100),
        ])
        // A 40-wide strip straddling the seam at x=80..120, y=10..30.
        let s = m.slices(displayID: 0, dirtyX: 80, dirtyY: 10, width: 40, height: 20)
        #expect(s == [
            ViewportMapper.Slice(viewportID: 0, headWidth: 100, headHeight: 100,
                                 destX: 80, destY: 10, srcX: 0, srcY: 0, width: 20, height: 20),
            ViewportMapper.Slice(viewportID: 1, headWidth: 100, headHeight: 100,
                                 destX: 0, destY: 10, srcX: 20, srcY: 0, width: 20, height: 20),
        ])
    }

    @Test func aWholeHeadSliceCoversTheDirtyRectExactly() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 100, height: 100)
        let s = m.slices(displayID: 0, dirtyX: 10, dirtyY: 20, width: 30, height: 40)
        #expect(s == [ViewportMapper.Slice(viewportID: 0, headWidth: 100, headHeight: 100,
                                           destX: 10, destY: 20, srcX: 0, srcY: 0, width: 30, height: 40)])
    }

    @Test func extractPullsATightlyPackedSubRect() {
        // 4x3 buffer whose pixel (x,y) has blue byte = y*16 + x; take the middle 2x2 at (1,1).
        var px = [UInt8](repeating: 0, count: 4 * 3 * 4)
        for y in 0 ..< 3 { for x in 0 ..< 4 { px[(y * 4 + x) * 4] = UInt8(y * 16 + x) } }
        let sub = ViewportMapper.extract(px, rowPixels: 4, x: 1, y: 1, width: 2, height: 2)
        #expect(sub.count == 2 * 2 * 4)
        #expect([sub[0], sub[4], sub[8], sub[12]] == [0x11, 0x12, 0x21, 0x22])
    }

    @Test func originTranslatesViewportToSurface() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 200, height: 100)
        m.headsChanged(displayID: 0, heads: [
            HeadRect(id: 0, x: 0, y: 0, width: 100, height: 100),
            HeadRect(id: 1, x: 100, y: 0, width: 100, height: 100),
        ])
        #expect(m.origin(of: 1)! == (displayID: 0, x: 100, y: 0))
        #expect(m.origin(of: 99) == nil)
    }

    @Test func tilingLaysEnabledMonitorsLeftToRight() {
        let monitors = MonitorTiling.compose([
            (width: 1920, height: 1080, enabled: true),
            (width: 1280, height: 800, enabled: false),
            (width: 2560, height: 1440, enabled: true),
        ])
        #expect(monitors == [
            AgentMonitorConfig(width: 1920, height: 1080, depth: 32, x: 0, y: 0),
            AgentMonitorConfig(width: 0, height: 0, depth: 0, x: 0, y: 0),
            AgentMonitorConfig(width: 2560, height: 1440, depth: 32, x: 1920, y: 0),
        ])
    }
}
