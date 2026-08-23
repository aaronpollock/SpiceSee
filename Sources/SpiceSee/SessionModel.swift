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

    private var frameSubscribers: [UUID: (viewportID: Int, continuation: AsyncStream<FrameUpdate>.Continuation)] = [:]
    private let backend: any SessionBackend
    private var pump: Task<Void, Never>?

    var connection: SavedConnection?
    var vmName: String { connection?.name ?? endpoint }

    init(backend: any SessionBackend) {
        self.backend = backend
    }

    /// Every viewport window gets its OWN stream. One shared stream would split frames between
    /// windows — each element is delivered to a single consumer — so a two-monitor guest would
    /// drop half its updates in each window.
    func frames(for viewportID: Int) -> AsyncStream<FrameUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: FrameUpdate.self, bufferingPolicy: .unbounded)
        let key = UUID()
        frameSubscribers[key] = (viewportID, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.frameSubscribers[key] = nil }
        }
        return stream
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
            agent = state
            // Without an agent the guest cannot deliver absolute pointer positions, so we capture.
            if state == .absent { pointerCaptured = true }
        case let .frame(update):
            for (_, subscriber) in frameSubscribers where subscriber.viewportID == update.viewportID {
                subscriber.continuation.yield(update)
            }
        case let .migrated(offer):
            migrationOffer = offer
        case let .failed(failure):
            phase = .failed(failure)
        case .disconnected:
            phase = .idle
            viewports = []
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
