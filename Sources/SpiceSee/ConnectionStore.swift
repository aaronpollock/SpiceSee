import Foundation
import Observation

/// Saved hosts, persisted as JSON in Application Support. Passwords live in the Keychain, never here.
@MainActor @Observable
final class ConnectionStore {
    private(set) var connections: [SavedConnection] = []
    var selection: SavedConnection.ID?
    var searchText: String = ""

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpiceSee", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }()

    /// Preview/mock stores never touch disk — otherwise sample hosts leak into the real store.
    private let isEphemeral: Bool

    init(connections: [SavedConnection]? = nil) {
        isEphemeral = connections != nil
        if let connections { self.connections = connections; return }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            self.connections = decoded
        }
    }

    var filtered: [SavedConnection] {
        guard !searchText.isEmpty else { return connections }
        return connections.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || $0.host.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selected: SavedConnection? {
        get { connections.first { $0.id == selection } }
        set {
            guard let newValue, let i = connections.firstIndex(where: { $0.id == newValue.id }) else { return }
            connections[i] = newValue
            save()
        }
    }

    func add() {
        let new = SavedConnection(name: "New Connection", host: "")
        connections.append(new)
        selection = new.id
        save()
    }

    func duplicate(_ connection: SavedConnection) {
        var copy = connection
        copy.id = UUID()
        copy.name = "\(connection.name) copy"
        copy.lastConnected = nil
        connections.append(copy)
        selection = copy.id
        save()
    }

    func remove(_ id: SavedConnection.ID) {
        connections.removeAll { $0.id == id }
        if selection == id { selection = nil }
        save()
    }

    private func save() {
        guard !isEphemeral, let data = try? JSONEncoder().encode(connections) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Sample hosts matching the design artboards — used by previews and `--mock`.
    static var preview: ConnectionStore {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 9, minute: 14, second: 0, of: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.date(bySettingHour: 17, minute: 2, second: 0, of: Date()) ?? Date())
        let store = ConnectionStore(connections: [
            SavedConnection(name: "win11-desk", host: "192.168.1.20", port: 5900, tlsPort: 5901,
                            lastConnected: today, agentWasPresent: true),
            SavedConnection(name: "ubuntu-build", host: "pve.lan", port: 5901, lastConnected: yesterday),
            SavedConnection(name: "opnsense", host: "10.0.0.4", port: 5900),
            SavedConnection(name: "truenas-console", host: "10.0.0.9", port: 5902,
                            lastConnected: cal.date(from: DateComponents(year: cal.component(.year, from: Date()), month: 8, day: 12))),
        ])
        store.selection = store.connections.first?.id
        return store
    }
}

extension SavedConnection {
    /// "192.168.1.20:5900 · Today 09:14" — the sidebar row's second line.
    var sidebarSubtitle: String {
        let endpoint = "\(host):\(port)"
        guard let lastConnected else { return endpoint }
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(lastConnected) {
            formatter.dateFormat = "HH:mm"
            return "\(endpoint) · Today \(formatter.string(from: lastConnected))"
        }
        if Calendar.current.isDateInYesterday(lastConnected) {
            formatter.dateFormat = "HH:mm"
            return "\(endpoint) · Yesterday \(formatter.string(from: lastConnected))"
        }
        formatter.dateFormat = "d MMM"
        return "\(endpoint) · \(formatter.string(from: lastConnected))"
    }
}

extension ConnectionStore {
    func addImported(_ connection: SavedConnection) {
        connections.append(connection)
        selection = connection.id
    }
}
