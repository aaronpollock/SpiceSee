import SwiftUI

@main
struct SpiceSeeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var opener = VVOpener()
    @State private var store = ConnectionStore.isRunningMock ? .preview : ConnectionStore()
    @State private var settings = AppSettings()
    @State private var session = SessionModel(backend: ConnectionStore.isRunningMock
        ? MockSessionBackend(scenario: MockSessionBackend.launchScenario)
        : SpiceKitBackend())

    var body: some Scene {
        Window("SpiceSee", id: "manager") {
            ConnectionManagerView(store: store, settings: settings, session: session)
                .task {
                    AppDelegate.openHandler = { url in
                        openWindow(id: "manager")
                        opener.open(url, store: store, session: session, settings: settings)
                    }
                    AppDelegate.drainPending()
                    // --mock --autoconnect drives the whole flow without a server, for design review.
                    if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
                        switch CommandLine.arguments[i + 1] {
                        case "acknowledgements": openWindow(id: "acknowledgements")
                        case "settings":
                            try? await Task.sleep(for: .milliseconds(600))
                            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                                _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                            }
                        default: break
                        }
                    }
                    guard CommandLine.arguments.contains("--autoconnect"),
                          let connection = store.selected else { return }
                    session.connect(connection, password: nil)
                }
                .onChange(of: settings.sendLockKeys, initial: true) { _, on in session.sendLockKeys = on }
        }
        .defaultSize(Metric.Window.connectionManager)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Both reopen the manager first: with every window closed the app is still running,
            // and neither command has anywhere to show its result otherwise.
            CommandGroup(replacing: .newItem) {
                Button("Add Connection…") {
                    openWindow(id: "manager")
                    store.add()
                }
                .keyboardShortcut("n")
                Button("Open .vv File…") {
                    openWindow(id: "manager")
                    openVVFile()
                }
                .keyboardShortcut("o")
            }
            // Closing a viewport window otherwise left no way to get it back.
            CommandGroup(after: .windowList) {
                Divider()
                Button("Show All Displays") { showAllDisplays(session, using: openWindow) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                ForEach(session.viewports) { viewport in
                    displayMenuItem(viewport)
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About SpiceSee") { NSApp.orderFrontStandardAboutPanel(nil) }
                Button("Acknowledgements…") { openWindow(id: "acknowledgements") }
            }
        }

        WindowGroup(id: "session", for: ViewportInfo.ID.self) { $viewportID in
            // `knownViewports`: a reopened window for a disabled head has to render, because it is
            // the window reporting its size that asks the guest to re-enable that head.
            if let viewport = session.knownViewports.first(where: { $0.id == viewportID }) {
                SessionWindowView(session: session, viewport: viewport)
            }
        }
        .defaultSize(Metric.Window.session)
        .windowStyle(.titleBar)

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(Metric.Window.acknowledgements)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(settings: settings)
        }
    }

    @Environment(\.openWindow) private var openWindow

    /// ⌘1…⌘9 for the first nine displays; beyond that the item still works, just without a shortcut.
    @ViewBuilder
    private func displayMenuItem(_ viewport: ViewportInfo) -> some View {
        let button = Button(viewport.menuTitle) { openWindow(id: "session", value: viewport.id) }
        if viewport.index < 9 {
            button.keyboardShortcut(KeyEquivalent(Character(String(viewport.index + 1))), modifiers: .command)
        } else {
            button
        }
    }

    private func openVVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.vvConnection]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        opener.open(url, store: store, session: session, settings: settings)
    }
}

/// Finder and the Proxmox web UI hand `.vv` files to the app through the delegate, not through a
/// SwiftUI scene — `Window` has no document support.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the manager window once the app's state objects exist; a file opened during launch
    /// waits here until then.
    @MainActor static var openHandler: ((URL) -> Void)?
    @MainActor private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if let handler = Self.openHandler { handler(url) } else { Self.pending.append(url) }
            }
        }
    }

    @MainActor
    static func drainPending() {
        guard let handler = openHandler else { return }
        let urls = pending
        pending = []
        urls.forEach(handler)
    }
}

import UniformTypeIdentifiers

extension UTType {
    static let vvConnection = UTType(importedAs: "org.spice-space.vv")
}

extension ConnectionStore {
    /// `--mock` (or SPICESEE_MOCK=1) seeds the artboard hosts so every screen can be reviewed without a server.
    static var isRunningMock: Bool {
        CommandLine.arguments.contains("--mock") || ProcessInfo.processInfo.environment["SPICESEE_MOCK"] == "1"
    }
}

extension MockSessionBackend {
    /// `--scenario desktop|noAgent|refused|badPassword|certMismatch|migrate`
    static var launchScenario: Scenario {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--scenario"), i + 1 < args.count,
              let scenario = Scenario(rawValue: args[i + 1]) else { return .desktop }
        return scenario
    }
}
