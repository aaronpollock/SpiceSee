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
    private(set) var agent: AgentState = .negotiating
    private(set) var endpoint: String = ""
    var migrationOffer: MigrationOffer?

    // Per-session view state, seeded from the connection's Advanced settings.
    var scaling: ScalingMode = .fit
    var hiDPI = false
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
        hiDPI = connection.advanced.hiDPI
        releaseChord = connection.advanced.releaseChord
        keyboardMapping = KeyboardMapping(commandMapsTo: connection.advanced.commandMapsTo,
                                          optionMapsTo: connection.advanced.optionMapsTo)
        phase = .connecting(completed: [])
        phaseBeforeFileFailure = nil
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
        case let .connected(viewports):
            self.viewports = viewports
            phase = .connected
            clipboard.start()
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
            phaseBeforeFileFailure = nil   // a real failure ends the session: dismissing must reach .idle
            phase = .failed(failure)
            clipboard.stop()
            for v in viewports { publish(.streamDestroyed(nil), to: v.id) }
        case .disconnected:
            phase = .idle
            for v in viewports { publish(.streamDestroyed(nil), to: v.id) }
            viewports = []
            pointerCaptured = false
            clipboard.stop()
        }
    }

    func retry(password: String?) {
        guard let connection else { return }
        connect(connection, password: password)
    }

    func cancel() {
        pump?.cancel()
        clipboard.stop()
        phase = .idle
        Task { [backend] in await backend.disconnect() }
    }

    func disconnect() {
        pump?.cancel()
        clipboard.stop()
        viewports = []
        phase = .idle
        Task { [backend] in await backend.disconnect() }
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
