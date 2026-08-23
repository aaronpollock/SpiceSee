import SwiftUI

@main
struct SpiceSeeApp: App {
    @State private var store = ConnectionStore.isRunningMock ? .preview : ConnectionStore()
    @State private var settings = AppSettings()
    @State private var session = SessionModel(backend: MockSessionBackend(scenario: MockSessionBackend.launchScenario))

    var body: some Scene {
        Window("SpiceSee", id: "manager") {
            ConnectionManagerView(store: store, settings: settings, session: session)
        }
        .defaultSize(Metric.Window.connectionManager)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Connection…") { store.add() }.keyboardShortcut("n")
                Button("Open .vv File…") { openVVFile() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appInfo) {
                Button("About SpiceSee") { NSApp.orderFrontStandardAboutPanel(nil) }
                Button("Acknowledgements…") { openWindow(id: "acknowledgements") }
            }
        }

        WindowGroup(id: "session", for: ViewportInfo.ID.self) { $viewportID in
            if let viewport = session.viewports.first(where: { $0.id == viewportID }) {
                SessionWindowView(session: session, viewport: viewport)
            }
        }
        .defaultSize(Metric.Window.session)
        .windowStyle(.titleBar)

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(Metric.Window.acknowledgements)

        Settings {
            SettingsView(settings: settings)
        }
    }

    @Environment(\.openWindow) private var openWindow

    private func openVVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.vvConnection]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importVV(at: url)
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

    /// Parses a Proxmox `.vv` INI and adds it as a connection. Full parsing lands with SpiceCore in M3.
    func importVV(at url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        guard let host = fields["host"] else { return }
        var connection = SavedConnection(name: fields["title"] ?? host, host: host)
        if let port = fields["port"], let p = UInt16(port) { connection.port = p }
        if let tls = fields["tls-port"], let p = UInt16(tls) { connection.tlsPort = p }
        addImported(connection)
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
