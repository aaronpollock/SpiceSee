import Testing
@testable import SpiceSee

@MainActor
@Suite struct ViewportSeamTests {
    /// Yields a scripted event list, then idles so the session stays up.
    private final class ScriptedBackend: SessionBackend {
        let script: [BackendEvent]
        init(script: [BackendEvent]) { self.script = script }
        func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> {
            AsyncStream { c in
                for e in script { c.yield(e) }
            }
        }
        func disconnect() async {}
        func sendCtrlAltDel() async {}
        func sendInput(_ event: InputEvent) {}
        func offerClipboardText() async {}
        func sendClipboardText(_ text: String) async {}
        func requestClipboardText() async {}
    }

    @Test func viewportsChangedReplacesTheListWithoutTouchingThePhase() async throws {
        let one = [ViewportInfo(id: 0, index: 0, total: 1, width: 1920, height: 1080)]
        let two = [ViewportInfo(id: 0, index: 0, total: 2, width: 1920, height: 1080),
                   ViewportInfo(id: 1, index: 1, total: 2, width: 1280, height: 800)]
        let model = SessionModel(backend: ScriptedBackend(script: [
            .connected(viewports: one), .viewportsChanged(two),
        ]))
        model.connect(SavedConnection(name: "t", host: "h"), password: nil)
        // The scripted stream is synchronous; give the pump a beat to drain.
        for _ in 0 ..< 100 where model.viewports.count != 2 { await Task.yield() }
        #expect(model.phase == .connected)
        #expect(model.viewports == two)
    }
}
