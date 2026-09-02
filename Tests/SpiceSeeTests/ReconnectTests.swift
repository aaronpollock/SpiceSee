import Foundation
import Testing
@testable import SpiceSee

/// One session at a time: connecting while another is live must tear that one down first, or its
/// viewport windows survive and render the new guest alongside the new session's own windows.
@MainActor
@Suite struct ReconnectTests {
    private actor CallLog {
        private(set) var calls: [String] = []
        func record(_ c: String) { calls.append(c) }
    }

    private final class Backend: SessionBackend {
        let log = CallLog()
        let stream: AsyncStream<BackendEvent>
        let events: AsyncStream<BackendEvent>.Continuation
        init() { (stream, events) = AsyncStream.makeStream(of: BackendEvent.self, bufferingPolicy: .unbounded) }
        func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> {
            Task { await log.record("connect \(target.host)") }
            return stream
        }
        func requestDisplayLayout(_ layouts: [DisplayLayout]) async {}
        func disconnect() async { await log.record("disconnect") }
        func sendCtrlAltDel() async {}
        func sendInput(_ event: InputEvent) {}
        func offerClipboard(_ kinds: [ClipboardKind]) async {}
        func sendClipboardText(_ text: String) async {}
        func sendClipboardPNG(_ bytes: [UInt8]) async {}
        func requestClipboard(_ kind: ClipboardKind) async {}
    }

    private func connected(_ backend: Backend) async -> SessionModel {
        let model = SessionModel(backend: backend)
        model.connect(SavedConnection(name: "a", host: "a"), password: nil)
        backend.events.yield(.connected(viewports: [ViewportInfo(id: 0, index: 0, total: 1, width: 1280, height: 800)]))
        for _ in 0 ..< 200 where model.phase != .connected { await Task.yield() }
        return model
    }

    /// Emptying `viewports` is what closes the old windows, and it has to happen before the new
    /// session's viewports arrive — so synchronously, in `connect` itself.
    @Test func connectingOverALiveSessionClosesItsViewportsFirst() async {
        let backend = Backend()
        let model = await connected(backend)
        #expect(model.viewports.count == 1)

        model.connect(SavedConnection(name: "b", host: "b"), password: nil)
        #expect(model.viewports.isEmpty)
        #expect(model.knownViewports.isEmpty)
    }

    /// The old session is closed before the new one dials, in order — not in a detached task that
    /// could run after the new session is stored and close that instead.
    @Test func connectingOverALiveSessionDisconnectsBeforeDialling() async {
        let backend = Backend()
        let model = await connected(backend)

        model.connect(SavedConnection(name: "b", host: "b"), password: nil)
        var calls: [String] = []
        for _ in 0 ..< 500 {
            calls = await backend.log.calls
            if calls.count >= 4 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        // Every connect clears the backend first; on the first one that is a no-op.
        #expect(calls.suffix(3) == ["connect a", "disconnect", "connect b"])
    }
}
