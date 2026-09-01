import AppKit
import Testing

/// `ClipboardBridge` is the one piece of clipboard logic that cannot live below `SpiceKit` — it
/// needs `NSPasteboard` — and it is where the host-to-guest direction broke: the guest could paste
/// into the Mac, but nothing the Mac copied ever reached the guest.
@MainActor
@Suite struct ClipboardBridgeTests {
    private final class FakeBackend: SessionBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        private func record(_ s: String) { lock.withLock { _calls.append(s) } }
        func clear() { lock.withLock { _calls.removeAll() } }

        func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> { .init { $0.finish() } }
        func disconnect() async {}
        func sendCtrlAltDel() async {}
        func sendInput(_ event: InputEvent) {}
        func offerClipboardText() async { record("offer") }
        func sendClipboardText(_ text: String) async { record("send(\(text))") }
        func requestClipboardText() async { record("request") }
        func requestDisplayLayout(_ layouts: [DisplayLayout]) async {}
    }

    /// A pasteboard of its own, so a test never disturbs what the user has copied.
    private func scratchPasteboard(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("com.spicesee.tests.\(name)"))
        pb.clearContents()
        return pb
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }
    /// Longer than `ClipboardBridge`'s poll interval, so one tick is guaranteed to have run.
    private func poll() async throws { try await Task.sleep(for: .milliseconds(900)) }

    /// The regression. Capability negotiation normally finishes before the primary surface exists,
    /// so `.available(true)` arrives *before* the `.connected` that starts the poll. `start()` used
    /// to clear `available`, and every later host copy was then silently dropped.
    @Test func aHostCopyIsOfferedWhenTheAgentNegotiatedBeforeTheSurfaceArrived() async throws {
        let pb = scratchPasteboard("order-a")
        pb.setString("initial", forType: .string)
        let backend = FakeBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)

        bridge.handle(.available(true))
        try await settle()
        bridge.start()
        try await settle()
        backend.clear()

        pb.clearContents()
        pb.setString("copied on the mac", forType: .string)
        try await poll()

        #expect(backend.calls.contains("offer"))
    }

    @Test func aHostCopyIsOfferedWhenTheSurfaceArrivedFirst() async throws {
        let pb = scratchPasteboard("order-b")
        pb.setString("initial", forType: .string)
        let backend = FakeBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)

        bridge.start()
        try await settle()
        bridge.handle(.available(true))
        try await settle()
        backend.clear()

        pb.clearContents()
        pb.setString("copied on the mac", forType: .string)
        try await poll()

        #expect(backend.calls.contains("offer"))
    }

    @Test func nothingIsOfferedBeforeAnAgentIsThere() async throws {
        let pb = scratchPasteboard("no-agent")
        let backend = FakeBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.start()
        try await settle()

        pb.clearContents()
        pb.setString("copied on the mac", forType: .string)
        try await poll()

        #expect(backend.calls.isEmpty)
    }

    /// Text arriving from the guest is written to the pasteboard, and must not then be offered
    /// straight back — that would bounce the same string between the two sides forever.
    @Test func guestTextIsNotEchoedBackToTheGuest() async throws {
        let pb = scratchPasteboard("echo")
        let backend = FakeBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        try await settle()
        backend.clear()

        bridge.handle(.guestText("from the guest"))
        try await poll()

        #expect(pb.string(forType: .string) == "from the guest")
        #expect(!backend.calls.contains("offer"))
    }

    @Test func aGuestOfferIsFetched() async throws {
        let pb = scratchPasteboard("fetch")
        let backend = FakeBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        try await settle()
        backend.clear()

        bridge.handle(.guestOffersText)
        try await settle()

        #expect(backend.calls == ["request"])
    }

    @Test func aGuestPasteIsAnsweredWithTheHostPasteboard() async throws {
        let pb = scratchPasteboard("answer")
        pb.setString("on the mac", forType: .string)
        let backend = FakeBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        try await settle()
        backend.clear()

        bridge.handle(.guestRequestsText)
        try await settle()

        #expect(backend.calls == ["send(on the mac)"])
    }

    /// The toolbar toggle has to stop both directions, not just one.
    @Test func theToggleStopsBothDirections() async throws {
        let pb = scratchPasteboard("disabled")
        pb.setString("on the mac", forType: .string)
        let backend = FakeBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        try await settle()
        bridge.enabled = false
        backend.clear()

        bridge.handle(.guestOffersText)
        bridge.handle(.guestRequestsText)
        pb.clearContents()
        pb.setString("copied while off", forType: .string)
        try await poll()

        #expect(backend.calls.isEmpty)
    }

    /// Events are queued through one consumer precisely so this cannot reorder: an offer that
    /// overtook the `.available(true)` enabling it would be dropped.
    @Test func eventsAreHandledInOrder() async throws {
        let pb = scratchPasteboard("ordering")
        pb.setString("on the mac", forType: .string)
        let backend = FakeBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)

        bridge.handle(.available(true))
        bridge.handle(.guestRequestsText)
        try await settle()

        // The initial offer that `.available(true)` triggers, then the answer — in that order.
        #expect(backend.calls == ["offer", "send(on the mac)"])
    }
}
