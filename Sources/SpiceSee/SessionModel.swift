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

    let frames: AsyncStream<FrameUpdate>
    private let frameContinuation: AsyncStream<FrameUpdate>.Continuation
    private let backend: any SessionBackend
    private var pump: Task<Void, Never>?

    var connection: SavedConnection?
    var vmName: String { connection?.name ?? endpoint }

    init(backend: any SessionBackend) {
        self.backend = backend
        (frames, frameContinuation) = AsyncStream.makeStream(of: FrameUpdate.self, bufferingPolicy: .unbounded)
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
            frameContinuation.yield(update)
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
}
