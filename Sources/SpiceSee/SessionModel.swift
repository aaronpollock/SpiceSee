import Observation
import SwiftUI

/// Drives one connection attempt and, once connected, its viewport windows.
@MainActor @Observable
final class SessionModel {
    enum Phase: Equatable {
        case idle
        case connecting(completed: Set<ConnectStep>)
        case connected
        case failed(ConnectFailure)
    }

    private(set) var phase: Phase = .idle
    private(set) var viewports: [ViewportInfo] = []
    /// Every viewport seen since connect, including heads the guest has since dropped. A head whose
    /// window is closed is asked to be disabled, so the guest stops reporting it — without this it
    /// could never be offered back, and Show All Displays is the only way to re-enable one.
    private(set) var knownViewports: [ViewportInfo] = []
    private(set) var agent: AgentState = .negotiating
    private(set) var endpoint: String = ""
    var migrationOffer: MigrationOffer?

    // Per-session view state, seeded from the connection's Advanced settings.
    var scaling: ScalingMode = .fit
    var hiDPI = false {
        didSet { scheduleResizeRequest() }
    }
    var clipboardSync = true {
        didSet { clipboard.enabled = clipboardSync }
    }
    var muted = false
    var pointerCaptured = false
    var releaseChord: ReleaseChord = .controlOption
    private(set) var pointerMode: PointerMode = .client
    var keyboardMapping = KeyboardMapping()
    /// Mirrors AppSettings.sendLockKeys; SpiceSeeApp keeps it current.
    var sendLockKeys = true

    /// How long after the channels come up to wait for a primary surface before opening a
    /// placeholder viewport anyway. A guest with a blanked console sends no surface until it
    /// gets input, and it can only get input through a window — without this, that guest is
    /// an unfailable, uncancellable spinner.
    var displayGraceSeconds: Double = 2
    private var graceTask: Task<Void, Never>?

    /// Resize-follows-window. Sizes are requested, not imposed: the guest answers with a new
    /// primary, which flows back as `.viewportsChanged`. The first report per viewport and any
    /// report matching the guest's current size are recorded but not sent — those are windows
    /// opening or fitting, not the user asking for a resolution.
    var resizeDebounce: Duration = .milliseconds(250)
    private var resizeTask: Task<Void, Never>?
    private var windowMetrics: [Int: (points: CGSize, backingScale: CGFloat)] = [:]

    /// Set only by `presentFailure`, so `dismissFailure` can put back a session the file error
    /// interrupted. Cleared the moment it is used or made stale by a real connect attempt.
    private var phaseBeforeFileFailure: Phase?

    private var viewportSubscribers: [UUID: (viewportID: Int, continuation: AsyncStream<ViewportEvent>.Continuation)] = [:]
    private let backend: any SessionBackend
    private let clipboard: ClipboardBridge
    private var pump: Task<Void, Never>?

    var connection: SavedConnection?
    var vmName: String { connection?.name ?? endpoint }

    init(backend: any SessionBackend) {
        self.backend = backend
        clipboard = ClipboardBridge(backend: backend)
    }

    /// Every viewport window gets its OWN stream. One shared stream would split events between
    /// windows — each element is delivered to a single consumer — so a two-monitor guest would
    /// drop half its updates in each window.
    func viewportEvents(for viewportID: Int) -> AsyncStream<ViewportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ViewportEvent.self, bufferingPolicy: .unbounded)
        let key = UUID()
        viewportSubscribers[key] = (viewportID, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.viewportSubscribers[key] = nil }
        }
        return stream
    }

    private func publish(_ event: ViewportEvent, to viewportID: Int) {
        for (_, s) in viewportSubscribers where s.viewportID == viewportID { s.continuation.yield(event) }
    }

    var completedSteps: Set<ConnectStep> {
        if case let .connecting(completed) = phase { return completed }
        return phase == .connected ? Set(ConnectStep.allCases) : []
    }

    func connect(_ connection: SavedConnection, password: String?) {
        self.connection = connection
        endpoint = connection.endpoint
        scaling = .fit
        // `hiDPI` is assigned before `phase` leaves `.connected`, so a reconnect over a live session
        // would otherwise arm a debounce from the old session's windows.
        resizeTask?.cancel()
        windowMetrics.removeAll()
        knownViewports = []
        hiDPI = connection.advanced.hiDPI
        releaseChord = connection.advanced.releaseChord
        keyboardMapping = KeyboardMapping(commandMapsTo: connection.advanced.commandMapsTo,
                                          optionMapsTo: connection.advanced.optionMapsTo)
        phase = .connecting(completed: [])
        phaseBeforeFileFailure = nil
        graceTask?.cancel()
        pump?.cancel()
        pump = Task { [backend] in
            let target = ConnectionTarget(host: connection.host,
                                          port: connection.port == 0 ? nil : connection.port,
                                          tlsPort: connection.tlsPort,
                                          hostSubject: connection.hostSubject,
                                          caPEM: connection.caPEM,
                                          password: password,
                                          proxy: connection.proxy)
            for await event in backend.connect(target) { apply(event) }
        }
    }

    private func apply(_ event: BackendEvent) {
        switch event {
        case let .step(step):
            if case let .connecting(done) = phase { phase = .connecting(completed: done.union([step])) }
            if step == .channels { startGracePeriod() }
        case let .connected(viewports):
            graceTask?.cancel()
            self.viewports = viewports
            mergeKnown(viewports)
            phase = .connected
            clipboard.start()
        case let .viewportsChanged(viewports):
            self.viewports = viewports
            mergeKnown(viewports)
        case let .clipboard(event):
            clipboard.handle(event)
        case let .agent(state):
            agent = state          // capture is decided by pointer mode now, not by agent presence
        case let .pointerMode(mode):
            pointerMode = mode
            if mode == .client { pointerCaptured = false }   // an agent came up: absolute pointer, nothing to release
        case let .frame(update):
            publish(.frame(update), to: update.viewportID)
        case let .cursor(viewportID, change):
            publish(.cursor(change), to: viewportID)
        case let .streamFrame(update):
            publish(.stream(update), to: update.viewportID)
        case let .streamDestroyed(viewportID, streamID):
            publish(.streamDestroyed(streamID), to: viewportID)
        case var .migrated(offer):
            // The backend knows only the host it dialled; the sheet quotes the VM by the name the
            // user gave the connection.
            if let name = connection?.name, !name.isEmpty { offer.vmName = name }
            migrationOffer = offer
        case let .failed(failure):
            graceTask?.cancel()
            phaseBeforeFileFailure = nil   // a real failure ends the session: dismissing must reach .idle
            phase = .failed(failure)
            clipboard.stop()
            for v in viewports { publish(.streamDestroyed(nil), to: v.id) }
            resizeTask?.cancel()
            windowMetrics.removeAll()
            knownViewports = []
        case .disconnected:
            graceTask?.cancel()
            phase = .idle
            for v in viewports { publish(.streamDestroyed(nil), to: v.id) }
            viewports = []
            pointerCaptured = false
            clipboard.stop()
            resizeTask?.cancel()
            windowMetrics.removeAll()
            knownViewports = []
        }
    }

    /// Latest size wins for a head still present; a head that vanished keeps its last known entry.
    private func mergeKnown(_ viewports: [ViewportInfo]) {
        var merged = knownViewports
        for v in viewports {
            if let i = merged.firstIndex(where: { $0.id == v.id }) { merged[i] = v } else { merged.append(v) }
        }
        knownViewports = merged
    }

    func retry(password: String?) {
        guard let connection else { return }
        connect(connection, password: password)
    }

    func cancel() {
        pump?.cancel()
        clipboard.stop()
        phase = .idle
        resizeTask?.cancel()
        windowMetrics.removeAll()
        knownViewports = []
        Task { [backend] in await backend.disconnect() }
    }

    private func startGracePeriod() {
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            guard let seconds = self?.displayGraceSeconds else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, case .connecting = self.phase else { return }
            self.apply(.connected(viewports: [ViewportInfo(id: 0, index: 0, total: 1, width: 1280, height: 800)]))
        }
    }

    func disconnect() {
        graceTask?.cancel()
        pump?.cancel()
        clipboard.stop()
        viewports = []
        phase = .idle
        resizeTask?.cancel()
        windowMetrics.removeAll()
        knownViewports = []
        Task { [backend] in await backend.disconnect() }
    }

    func viewportSizeChanged(_ viewportID: Int, points: CGSize, backingScale: CGFloat) {
        let first = windowMetrics[viewportID] == nil
        windowMetrics[viewportID] = (points, backingScale)
        // A first report for a head the guest is not currently showing is a window being reopened
        // for a head that was disabled — that report IS the request to bring it back. For a head
        // already in the layout it is only the window opening, and stays suppressed.
        let disabled = !viewports.contains { $0.id == viewportID }
        guard !first || disabled else { return }
        let (w, h) = requestedPixels(points: points, backingScale: backingScale)
        if let current = viewports.first(where: { $0.id == viewportID }),
           current.width == w, current.height == h { return }
        scheduleResizeRequest()
    }

    func viewportWindowClosed(_ viewportID: Int) {
        windowMetrics[viewportID] = nil
        guard phase == .connected else { return }
        scheduleResizeRequest()
    }

    private func requestedPixels(points: CGSize, backingScale: CGFloat) -> (Int, Int) {
        let s = hiDPI ? backingScale : 1
        return (Int((points.width * s).rounded()), Int((points.height * s).rounded()))
    }

    private func scheduleResizeRequest() {
        // `hiDPI`'s didSet fires this during `connect()`'s initial seed assignment too, before
        // `phase` becomes `.connecting` — guarding here (not just in the debounced task) stops
        // that from leaving a stray task alive that could later fire once a window's first report
        // has populated `windowMetrics`, wrongly sending a size nobody asked for.
        guard phase == .connected else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            guard let debounce = self?.resizeDebounce else { return }
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled, self.phase == .connected, self.agent == .connected else { return }
            let open = Set(self.viewportSubscribers.values.map(\.viewportID))
            guard !open.isEmpty else { return }   // never disable every head from the Window menu
            // Over `knownViewports`, not `viewports`: a head the guest dropped when its window
            // closed has to stay in the layout to be offered back as enabled when it reopens.
            let layouts = self.knownViewports.map { v -> DisplayLayout in
                guard open.contains(v.id) else {
                    return DisplayLayout(viewportID: v.id, width: 0, height: 0, enabled: false)
                }
                let (w, h) = self.windowMetrics[v.id].map { self.requestedPixels(points: $0.points, backingScale: $0.backingScale) }
                    ?? (v.width, v.height)
                return DisplayLayout(viewportID: v.id, width: w, height: h, enabled: true)
            }
            // Awaited inline, not in a nested task: two expiries must not reach the backend out of order.
            await self.backend.requestDisplayLayout(layouts)
        }
    }

    func sendInput(_ event: InputEvent) {
        guard phase == .connected else { return }
        backend.sendInput(event)
    }

    /// Called by the input view when it grabs or lets go of the pointer (server mode).
    func setPointerCaptured(_ captured: Bool) { pointerCaptured = captured }

    func sendCtrlAltDel() {
        guard phase == .connected else { return }
        Task { [backend] in await backend.sendCtrlAltDel() }
    }

    /// Shows a failure that happened before a connection was attempted (an unreadable `.vv`).
    ///
    /// A file that will not parse is not a session failure, so the phase in effect is remembered and
    /// dismissing the sheet must not tell the app the session ended — a guest may still be rendering.
    func presentFailure(_ failure: ConnectFailure) {
        if case .failed = phase {} else { phaseBeforeFileFailure = phase }
        phase = .failed(failure)
    }

    /// Dismiss a failure sheet, returning the detail pane to its editable form.
    ///
    /// Only `presentFailure` records a phase to go back to; a real connect failure has none, so it
    /// keeps landing in `.idle`.
    func dismissFailure() {
        guard case .failed = phase else { return }
        phase = phaseBeforeFileFailure ?? .idle
        phaseBeforeFileFailure = nil
    }

    /// Accept the migration offer: reconnect to the host the cluster moved the VM to.
    ///
    /// The CA is kept — a cluster CA does not change when a VM moves between its nodes — but the
    /// subject does, since it names the node, so it is replaced whenever the message supplied one.
    /// A target that offers a TLS port is reconnected over TLS; the plain port is not a fallback.
    func acceptMigration(host: String, port: UInt16?, tlsPort: UInt16?, certSubject: String?, password: String?) {
        guard var connection else { return }
        connection.host = host
        if let port { connection.port = port }
        connection.tlsPort = tlsPort
        if let certSubject { connection.hostSubject = certSubject }
        migrationOffer = nil
        connect(connection, password: password)
    }
}
