import AppKit

/// Keeps the Mac pasteboard and the guest's clipboard in step.
///
/// Both directions are "by demand", which is what the agent protocol is built for: whoever copies
/// only *announces* it, and the bytes cross when the other side actually pastes. That keeps a large
/// copy off the wire until it is wanted, and it is why this type never pushes data on its own.
///
/// `NSPasteboard` has no change notification, so the host side is a poll of `changeCount` — the same
/// approach every Mac clipboard-watching app uses.
@MainActor
final class ClipboardBridge {
    private let backend: any SessionBackend
    private let pasteboard: NSPasteboard
    private var poll: Task<Void, Never>?
    /// The `changeCount` we are responsible for. Writing the guest's text into the pasteboard bumps
    /// the count, and offering that straight back would bounce the same text between the two sides.
    private var ownChangeCount: Int
    private var lastSeenChangeCount: Int
    private var available = false

    /// One FIFO with a single consumer, started in `init` and never cancelled — the same shape, and
    /// for the same reason, as the input queue in `SpiceKitBackend`. Handling each event in its own
    /// `Task` would let `.guestOffersText` overtake the `.available(true)` that enables it.
    private let events: AsyncStream<ClipboardEvent>
    private let eventCont: AsyncStream<ClipboardEvent>.Continuation
    private var consumer: Task<Void, Never>?

    /// How often the host pasteboard is checked. Fast enough that ⌘C then a paste in the guest feels
    /// immediate, slow enough to be free.
    private static let pollInterval = Duration.milliseconds(400)

    var enabled = true {
        didSet { if enabled, !oldValue { lastSeenChangeCount = pasteboard.changeCount } }
    }

    init(backend: any SessionBackend, pasteboard: NSPasteboard = .general) {
        self.backend = backend
        self.pasteboard = pasteboard
        ownChangeCount = pasteboard.changeCount
        lastSeenChangeCount = pasteboard.changeCount
        (events, eventCont) = AsyncStream.makeStream(of: ClipboardEvent.self, bufferingPolicy: .unbounded)
        consumer = Task { [weak self, events] in
            for await e in events {
                guard let self else { return }
                await self.process(e)
            }
        }
    }

    deinit { eventCont.finish() }

    func handle(_ event: ClipboardEvent) { eventCont.yield(event) }

    func start() {
        stop()
        lastSeenChangeCount = pasteboard.changeCount
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                await self.checkHostClipboard()
            }
        }
    }

    /// Ends the session's watch. The event consumer deliberately stays: cancelling it would leave
    /// every later session's clipboard silent, since it is never restarted.
    func stop() {
        poll?.cancel()
        poll = nil
        available = false
    }

    private func process(_ event: ClipboardEvent) async {
        switch event {
        case let .available(on):
            available = on
            // A guest that has just come up has not seen anything copied before now; offer what is
            // already on the pasteboard so the first paste works without a second ⌘C.
            if on, enabled, pasteboard.string(forType: .string) != nil {
                await backend.offerClipboardText()
            }
        case .guestOffersText:
            guard enabled else { return }
            await backend.requestClipboardText()
        case let .guestText(text):
            guard enabled else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            ownChangeCount = pasteboard.changeCount
            lastSeenChangeCount = pasteboard.changeCount
        case .guestRequestsText:
            guard enabled, let text = pasteboard.string(forType: .string) else { return }
            await backend.sendClipboardText(text)
        case .guestReleased:
            break   // the Mac pasteboard keeps what it has; nothing to clear
        }
    }

    private func checkHostClipboard() async {
        let count = pasteboard.changeCount
        guard count != lastSeenChangeCount else { return }
        lastSeenChangeCount = count
        guard enabled, available, count != ownChangeCount else { return }
        guard pasteboard.string(forType: .string) != nil else { return }
        await backend.offerClipboardText()
    }
}
