import SwiftUI

// Glue between the screens: which window presents what, and when. The individual screens are
// self-contained views; this file is the only place that decides how they are surfaced.

extension View {
    /// Presents `FailureSheet` over the connection manager whenever a connect attempt fails.
    func connectFailureSheet(session: SessionModel, onEditConnection: @escaping () -> Void,
                             onFetchVV: @escaping () -> Void) -> some View {
        modifier(ConnectFailurePresenter(session: session, onEditConnection: onEditConnection, onFetchVV: onFetchVV))
    }

    /// Opens one viewport window per guest monitor once the session connects.
    func opensSessionWindows(session: SessionModel, settings: AppSettings) -> some View {
        modifier(SessionWindowOpener(session: session, settings: settings))
    }

    /// Presents `MigrationSheet` on the session window, per the design: the dialog belongs to the
    /// window that received MAIN_MIGRATE_SWITCH_HOST, not to the connection manager.
    func migrationSheet(session: SessionModel, viewport: ViewportInfo) -> some View {
        modifier(MigrationPresenter(session: session, viewport: viewport))
    }
}

private struct ConnectFailurePresenter: ViewModifier {
    let session: SessionModel
    let onEditConnection: () -> Void
    let onFetchVV: () -> Void
    @State private var password = ""

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            if case let .failed(failure) = session.phase {
                FailureSheet(
                    failure: failure,
                    password: $password,
                    onCancel: { session.dismissFailure() },
                    onRetry: {
                        let entered = password
                        session.dismissFailure()
                        session.retry(password: entered.isEmpty ? nil : entered)
                    },
                    onSecondary: {
                        session.dismissFailure()
                        if case .refused = failure { onEditConnection() } else { onFetchVV() }
                    }
                )
            }
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { if case .failed = session.phase { return true }; return false },
            set: { if !$0 { session.dismissFailure() } }
        )
    }
}

/// Reopens one viewport window per guest monitor. Closing the displays leaves the session
/// running, so both the Window menu and the manager's Show Displays button land here.
@MainActor
func showAllDisplays(_ session: SessionModel, using openWindow: OpenWindowAction) {
    for viewport in session.viewports { openWindow(id: "session", value: viewport.id) }
}

private struct SessionWindowOpener: ViewModifier {
    let session: SessionModel
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onChange(of: session.viewports) { previous, viewports in
            // Disconnecting empties the list; without this the windows would survive with nothing
            // left to render in them.
            guard !viewports.isEmpty else {
                for viewport in previous { dismissWindow(id: "session", value: viewport.id) }
                return
            }
            let toOpen = settings.openWindowPerMonitor ? viewports : Array(viewports.prefix(1))
            for viewport in toOpen { openWindow(id: "session", value: viewport.id) }
        }
    }
}

private struct MigrationPresenter: ViewModifier {
    let session: SessionModel
    let viewport: ViewportInfo
    @State private var host = ""
    @State private var port = ""
    @State private var reconnectAutomatically = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            if let offer = session.migrationOffer {
                MigrationSheet(
                    offer: offer,
                    host: $host,
                    port: $port,
                    reconnectAutomatically: $reconnectAutomatically,
                    onCancel: { session.migrationOffer = nil },
                    onReconnect: { reconnect(to: offer) }
                )
            }
        }
        .onChange(of: session.migrationOffer) { _, offer in
            guard let offer else { return }
            host = offer.newHost
            port = String(offer.newTLSPort ?? offer.newPort)
        }
    }

    /// The single port field edits whichever port the cluster offered — the secure one when there
    /// is one, so an edited port never silently downgrades the reconnect to plain TCP.
    private func reconnect(to offer: MigrationOffer) {
        let entered = UInt16(port)
        let secure = offer.newTLSPort != nil
        session.acceptMigration(host: host,
                                port: secure ? nil : (entered ?? offer.newPort),
                                tlsPort: secure ? (entered ?? offer.newTLSPort) : nil,
                                certSubject: offer.certSubject,
                                password: nil)
    }

    /// Only one window shows the dialog, otherwise a two-monitor guest raises two of them.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { session.migrationOffer != nil && viewport.index == 0 },
            set: { if !$0 { session.migrationOffer = nil } }
        )
    }
}

/// Sizes and bounds the hosting window on first appearance.
///
/// SwiftUI sizes a `Window` whose content is vertically flexible to the screen's whole visible
/// height, which is how the connection manager ended up 1041pt tall — taller than the design's 520
/// and, once Advanced expanded, pushed off the top of the screen. `.defaultSize` does not survive
/// that. Clamping the content size here is deterministic, and the max keeps it on-screen.
struct WindowSizer: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func apply(to window: NSWindow?) {
        guard let window, !context(window) else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? size
        window.contentMinSize = CGSize(width: min(620, size.width), height: min(380, size.height))
        window.contentMaxSize = CGSize(width: .greatestFiniteMagnitude, height: visible.height)
        window.setContentSize(CGSize(width: min(size.width, visible.width),
                                     height: min(size.height, visible.height)))
        window.center()
        sized.insert(ObjectIdentifier(window))
    }

    /// Only the first appearance sizes the window; later ones would fight the user's own resizing.
    private func context(_ window: NSWindow) -> Bool { sized.contains(ObjectIdentifier(window)) }
}

@MainActor private var sized: Set<ObjectIdentifier> = []

extension View {
    func sizesWindow(to size: CGSize) -> some View {
        background(WindowSizer(size: size))
    }
}
