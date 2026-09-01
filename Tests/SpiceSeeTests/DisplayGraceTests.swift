import Foundation
import Testing
@testable import SpiceSee

/// A backend whose event stream the test scripts. Everything else is a no-op.
private struct StubBackend: SessionBackend {
    let script: @Sendable (AsyncStream<BackendEvent>.Continuation) -> Void
    func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> { AsyncStream { script($0) } }
    func disconnect() async {}
    func sendCtrlAltDel() async {}
    func sendInput(_ event: InputEvent) {}
    func offerClipboardText() async {}
    func sendClipboardText(_ text: String) async {}
    func requestClipboardText() async {}
    func requestDisplayLayout(_ layouts: [DisplayLayout]) async {}
}

/// A guest whose display is blanked sends no primary surface until it gets input — and it can
/// only get input once a window exists. The grace period breaks that deadlock: channels up but
/// no primary means open a placeholder viewport anyway.
struct DisplayGraceTests {
    @MainActor @Test func aSilentDisplayOpensAPlaceholderViewportAfterTheGracePeriod() async throws {
        let session = SessionModel(backend: StubBackend { cont in
            for step in ConnectStep.allCases { cont.yield(.step(step)) }
            // No .connected ever: the guest display is asleep.
        })
        session.displayGraceSeconds = 0.05
        session.connect(SavedConnection(name: "pve", host: "h"), password: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.phase == .connected)
        #expect(session.viewports.count == 1)
    }

    @MainActor @Test func aRealViewportListReplacesThePlaceholder() async throws {
        let session = SessionModel(backend: StubBackend { cont in
            for step in ConnectStep.allCases { cont.yield(.step(step)) }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                cont.yield(.connected(viewports: [ViewportInfo(id: 0, index: 0, total: 1, width: 1920, height: 1080)]))
            }
        })
        session.displayGraceSeconds = 0.05
        session.connect(SavedConnection(name: "pve", host: "h"), password: nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(session.viewports.map(\.width) == [1920])
    }

    @MainActor @Test func aPromptConnectNeverSeesThePlaceholder() async throws {
        let session = SessionModel(backend: StubBackend { cont in
            for step in ConnectStep.allCases { cont.yield(.step(step)) }
            cont.yield(.connected(viewports: [ViewportInfo(id: 0, index: 0, total: 1, width: 800, height: 600)]))
        })
        session.displayGraceSeconds = 0.05
        session.connect(SavedConnection(name: "pve", host: "h"), password: nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.viewports.map(\.width) == [800])
    }

    /// A failure during the grace window must win: the sheet shows the error, no ghost window.
    @MainActor @Test func aFailureCancelsTheGracePeriod() async throws {
        let session = SessionModel(backend: StubBackend { cont in
            for step in ConnectStep.allCases { cont.yield(.step(step)) }
            cont.yield(.failed(.refused(endpoint: "h:5900")))
        })
        session.displayGraceSeconds = 0.05
        session.connect(SavedConnection(name: "pve", host: "h"), password: nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.phase == .failed(.refused(endpoint: "h:5900")))
        #expect(session.viewports.isEmpty)
    }
}
