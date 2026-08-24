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
    var clipboardSync = true
    var muted = false
    var pointerCaptured = false
    var releaseChord: ReleaseChord = .controlOption
    private(set) var pointerMode: PointerMode = .client
    var keyboardMapping = KeyboardMapping()
    /// Mirrors AppSettings.sendLockKeys; SpiceSeeApp keeps it current.
    var sendLockKeys = true

    private var viewportSubscribers: [UUID: (viewportID: Int, continuation: AsyncStream<ViewportEvent>.Continuation)] = [:]
    private let backend: any SessionBackend
    private var pump: Task<Void, Never>?

    var connection: SavedConnection?
    var vmName: String { connection?.name ?? endpoint }

    init(backend: any SessionBackend) {
        self.backend = backend
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
        pump?.cancel()
        pump = Task { [backend] in
            for await event in backend.connect(host: connection.host, port: connection.port,
                                               tlsPort: connection.tlsPort, password: password) {
                apply(event)
            }
        }
    }

    private func apply(_ event: BackendEvent) {
        switch event {
        case let .step(step):
            if case let .connecting(done) = phase { phase = .connecting(completed: done.union([step])) }
        case let .connected(viewports):
            self.viewports = viewports
            phase = .connected
        case let .agent(state):
            agent = state          // capture is decided by pointer mode now, not by agent presence
        case let .pointerMode(mode):
            pointerMode = mode
            if mode == .client { pointerCaptured = false }   // an agent came up: absolute pointer, nothing to release
        case let .frame(update):
            publish(.frame(update), to: update.viewportID)
        case let .cursor(viewportID, change):
            publish(.cursor(change), to: viewportID)
        case let .migrated(offer):
            migrationOffer = offer
        case let .failed(failure):
            phase = .failed(failure)
        case .disconnected:
            phase = .idle
            viewports = []
            pointerCaptured = false
        }
    }

    func retry(password: String?) {
        guard let connection else { return }
        connect(connection, password: password)
    }

    func cancel() {
        pump?.cancel()
        phase = .idle
        Task { [backend] in await backend.disconnect() }
    }

    func disconnect() {
        pump?.cancel()
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

    func sendCtrlAltDel() { Task { [backend] in await backend.sendCtrlAltDel() } }

    func releasePointer() { pointerCaptured = false }

    /// Dismiss a failure sheet, returning the detail pane to its editable form.
    func dismissFailure() { if case .failed = phase { phase = .idle } }

    /// Accept the migration offer: reconnect to the host the cluster moved the VM to.
    func acceptMigration(host: String, port: UInt16, password: String?) {
        guard var connection else { return }
        connection.host = host
        connection.port = port
        connection.tlsPort = nil
        migrationOffer = nil
        connect(connection, password: password)
    }
}
