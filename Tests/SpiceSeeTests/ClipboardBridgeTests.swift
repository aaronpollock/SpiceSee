import AppKit
import Testing

/// `ClipboardBridge` is the one piece of clipboard logic that cannot live below `SpiceKit` — it
/// needs `NSPasteboard` — and it is where the host-to-guest direction broke: the guest could paste
/// into the Mac, but nothing the Mac copied ever reached the guest.
@MainActor
@Suite struct ClipboardBridgeTests {
    private actor SpyBackend: SessionBackend {
        private(set) var offers: [[ClipboardKind]] = []
        private(set) var requests: [ClipboardKind] = []
        private(set) var sentTexts: [String] = []
        private(set) var sentPNGs: [[UInt8]] = []
        /// One chronological log spanning every recorder below — the typed arrays above each lose
        /// cross-kind ordering, which is what actually proves the single-consumer FIFO processes
        /// events in the order they were queued rather than one `Task` per event racing another.
        private(set) var calls: [String] = []

        nonisolated func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> { .init { $0.finish() } }
        nonisolated func disconnect() async {}
        nonisolated func sendCtrlAltDel() async {}
        nonisolated func sendInput(_ event: InputEvent) {}
        nonisolated private func name(_ k: ClipboardKind) -> String { k == .text ? "text" : "png" }
        func offerClipboard(_ kinds: [ClipboardKind]) async {
            offers.append(kinds)
            calls.append("offer(\(kinds.map(name).joined(separator: ",")))")
        }
        func requestClipboard(_ kind: ClipboardKind) async {
            requests.append(kind)
            calls.append("request(\(name(kind)))")
        }
        func sendClipboardText(_ text: String) async {
            sentTexts.append(text)
            calls.append("send(\(text))")
        }
        func sendClipboardPNG(_ bytes: [UInt8]) async {
            sentPNGs.append(bytes)
            calls.append("sendPNG(\(bytes.count) bytes)")
        }
        nonisolated func requestDisplayLayout(_ layouts: [DisplayLayout]) async {}

        func clear() {
            offers.removeAll(); requests.removeAll(); sentTexts.removeAll(); sentPNGs.removeAll()
            calls.removeAll()
        }
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

    /// Polls a condition until it's true or a timeout elapses; the following `#expect` reports
    /// failure if it never was.
    private func drainUntil(timeout: Duration = .seconds(3), _ predicate: () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A tiny valid PNG, built the same way the host-side encode path does.
    private func pngFixture() -> [UInt8] {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("could not build PNG fixture")
        }
        return Array(png)
    }

    /// The regression. Capability negotiation normally finishes before the primary surface exists,
    /// so `.available(true)` arrives *before* the `.connected` that starts the poll. `start()` used
    /// to clear `available`, and every later host copy was then silently dropped.
    @Test func aHostCopyIsOfferedWhenTheAgentNegotiatedBeforeTheSurfaceArrived() async throws {
        let pb = scratchPasteboard("order-a")
        pb.setString("initial", forType: .string)
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)

        bridge.handle(.available(true))
        try await settle()
        bridge.start()
        try await settle()
        await backend.clear()

        pb.clearContents()
        pb.setString("copied on the mac", forType: .string)
        try await poll()

        #expect(await backend.offers.contains { $0.contains(.text) })
    }

    @Test func aHostCopyIsOfferedWhenTheSurfaceArrivedFirst() async throws {
        let pb = scratchPasteboard("order-b")
        pb.setString("initial", forType: .string)
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)

        bridge.start()
        try await settle()
        bridge.handle(.available(true))
        try await settle()
        await backend.clear()

        pb.clearContents()
        pb.setString("copied on the mac", forType: .string)
        try await poll()

        #expect(await backend.offers.contains { $0.contains(.text) })
    }

    @Test func nothingIsOfferedBeforeAnAgentIsThere() async throws {
        let pb = scratchPasteboard("no-agent")
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.start()
        try await settle()

        pb.clearContents()
        pb.setString("copied on the mac", forType: .string)
        try await poll()

        #expect(await backend.offers.isEmpty)
        #expect(await backend.requests.isEmpty)
    }

    /// Text arriving from the guest is written to the pasteboard, and must not then be offered
    /// straight back — that would bounce the same string between the two sides forever.
    @Test func guestTextIsNotEchoedBackToTheGuest() async throws {
        let pb = scratchPasteboard("echo")
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        try await settle()
        await backend.clear()

        bridge.handle(.guestText("from the guest"))
        try await poll()

        #expect(pb.string(forType: .string) == "from the guest")
        #expect(await !backend.offers.contains { $0.contains(.text) })
    }

    @Test func aGuestOfferIsFetched() async throws {
        let pb = scratchPasteboard("fetch")
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        try await settle()
        await backend.clear()

        bridge.handle(.guestOffers([.text]))
        try await settle()

        #expect(await backend.requests == [.text])
    }

    @Test func aGuestPasteIsAnsweredWithTheHostPasteboard() async throws {
        let pb = scratchPasteboard("answer")
        pb.setString("on the mac", forType: .string)
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        try await settle()
        await backend.clear()

        bridge.handle(.guestRequests(.text))
        try await settle()

        #expect(await backend.sentTexts == ["on the mac"])
    }

    /// The toolbar toggle has to stop both directions, not just one.
    @Test func theToggleStopsBothDirections() async throws {
        let pb = scratchPasteboard("disabled")
        pb.setString("on the mac", forType: .string)
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        try await settle()
        bridge.enabled = false
        await backend.clear()

        bridge.handle(.guestOffers([.text]))
        bridge.handle(.guestRequests(.text))
        pb.clearContents()
        pb.setString("copied while off", forType: .string)
        try await poll()

        #expect(await backend.offers.isEmpty)
        #expect(await backend.requests.isEmpty)
        #expect(await backend.sentTexts.isEmpty)
        #expect(await backend.sentPNGs.isEmpty)
    }

    /// Events are queued through one consumer precisely so this cannot reorder: an offer that
    /// overtook the `.available(true)` enabling it would be dropped.
    @Test func eventsAreHandledInOrder() async throws {
        let pb = scratchPasteboard("ordering")
        pb.setString("on the mac", forType: .string)
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)

        bridge.handle(.available(true))
        bridge.handle(.guestRequests(.text))
        try await settle()

        // The initial offer that `.available(true)` triggers, then the answer — in that order.
        // Asserted against the one chronological log spanning both recorders: a regression that
        // handled each event in its own `Task` could still leave both typed arrays populated,
        // just in whichever order the two tasks happened to race, and this is the assertion that
        // would catch it.
        #expect(await backend.calls == ["offer(text)", "send(on the mac)"])
    }

    @Test func hostImageIsOfferedAsPNG() async {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        pb.clearContents()
        pb.writeObjects([image])
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        await drainUntil { await backend.offers.contains([.png]) }
        #expect(await backend.offers.last == [.png])
    }

    @Test func aGuestPNGRequestIsAnsweredWithEncodedPNG() async {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        pb.clearContents(); pb.writeObjects([image])
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.handle(.guestRequests(.png))
        await drainUntil { await backend.sentPNGs.count == 1 }
        let png = await backend.sentPNGs.first ?? []
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])     // PNG magic
    }

    @Test func guestImageLandsOnThePasteboardWithoutBouncingBack() async {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        let png: [UInt8] = pngFixture()
        bridge.handle(.guestOffers([.png]))
        await drainUntil { await backend.requests.contains(.png) }
        bridge.handle(.guestImagePNG(png))
        await drainUntil { pb.data(forType: .png) != nil }
        #expect(pb.data(forType: .png).map(Array.init) == png)
        // The write bumped changeCount; the poll must not offer our own write back.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await backend.offers.count(where: { $0.contains(.png) }) == 0)
    }

    @Test func guestOfferingTextAndImageGetsAskedForText() async {
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend,
                                     pasteboard: NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)))
        bridge.handle(.available(true))
        bridge.handle(.guestOffers([.text, .png]))
        await drainUntil { !(await backend.requests.isEmpty) }
        #expect(await backend.requests == [.text])
    }
}
