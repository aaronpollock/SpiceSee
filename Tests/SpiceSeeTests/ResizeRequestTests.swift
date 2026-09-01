import Foundation
import Testing
@testable import SpiceSee

@MainActor
@Suite struct ResizeRequestTests {
    private actor LayoutSpy {
        private(set) var calls: [[DisplayLayout]] = []
        func record(_ l: [DisplayLayout]) { calls.append(l) }
    }

    private final class Backend: SessionBackend {
        let spy = LayoutSpy()
        func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> {
            AsyncStream { c in
                c.yield(.connected(viewports: [ViewportInfo(id: 0, index: 0, total: 1, width: 1920, height: 1080)]))
                c.yield(.agent(.connected))
            }
        }
        func requestDisplayLayout(_ layouts: [DisplayLayout]) async { await spy.record(layouts) }
        func disconnect() async {}
        func sendCtrlAltDel() async {}
        func sendInput(_ event: InputEvent) {}
        func offerClipboard(_ kinds: [ClipboardKind]) async {}
        func sendClipboardText(_ text: String) async {}
        func sendClipboardPNG(_ bytes: [UInt8]) async {}
        func requestClipboard(_ kind: ClipboardKind) async {}
    }

    // AsyncStream cancels itself the moment the returned value is deinitialized without ever
    // being iterated, so the "open window" stream must be retained for the test's duration —
    // discarding it to `_` looks like an open window but silently closes it right away.
    private func connectedModel(_ backend: Backend) async -> (SessionModel, AsyncStream<ViewportEvent>) {
        let model = SessionModel(backend: backend)
        model.resizeDebounce = .milliseconds(1)
        model.connect(SavedConnection(name: "t", host: "h"), password: nil)
        for _ in 0 ..< 200 where model.agent != .connected { await Task.yield() }
        let window = model.viewportEvents(for: 0)   // an open window, as MetalSurfaceView would register
        return (model, window)
    }

    private func drained(_ spy: LayoutSpy, count: Int) async -> [[DisplayLayout]] {
        for _ in 0 ..< 500 {
            if await spy.calls.count >= count { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await spy.calls
    }

    @Test func firstReportIsRecordedNotSent() async {
        let backend = Backend()
        let (model, window) = await connectedModel(backend)
        model.viewportSizeChanged(0, points: CGSize(width: 1440, height: 900), backingScale: 2)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.spy.calls.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func aResizeAfterTheFirstReportIsSentDebounced() async {
        let backend = Backend()
        let (model, window) = await connectedModel(backend)
        model.viewportSizeChanged(0, points: CGSize(width: 1440, height: 900), backingScale: 2)
        model.viewportSizeChanged(0, points: CGSize(width: 1500, height: 920), backingScale: 2)
        model.viewportSizeChanged(0, points: CGSize(width: 1512, height: 945), backingScale: 2)
        let calls = await drained(backend.spy, count: 1)
        #expect(calls == [[DisplayLayout(viewportID: 0, width: 1512, height: 945, enabled: true)]])
        withExtendedLifetime(window) {}
    }

    @Test func hiDPIScalesThePixelsAndRetriggers() async {
        let backend = Backend()
        let (model, window) = await connectedModel(backend)
        model.viewportSizeChanged(0, points: CGSize(width: 1440, height: 900), backingScale: 2)
        model.viewportSizeChanged(0, points: CGSize(width: 1500, height: 920), backingScale: 2)
        _ = await drained(backend.spy, count: 1)
        model.hiDPI = true
        let calls = await drained(backend.spy, count: 2)
        #expect(calls.last == [DisplayLayout(viewportID: 0, width: 3000, height: 1840, enabled: true)])
        withExtendedLifetime(window) {}
    }

    @Test func aReportMatchingTheGuestSizeIsNotEchoed() async {
        let backend = Backend()
        let (model, window) = await connectedModel(backend)
        model.viewportSizeChanged(0, points: CGSize(width: 800, height: 600), backingScale: 2)
        // The guest is already 1920x1080; a fitted window reporting exactly that must not resend.
        model.viewportSizeChanged(0, points: CGSize(width: 1920, height: 1080), backingScale: 2)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.spy.calls.isEmpty)
        withExtendedLifetime(window) {}
    }
}
