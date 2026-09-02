import Foundation
import SpiceCore
import Testing

@MainActor
@Suite struct ConnectionNamingTests {
    // MARK: Following the host

    @Test func anUnnamedConnectionFollowsTheHost() {
        var c = SavedConnection(name: SavedConnection.placeholderName, nameIsCustom: false, host: "")
        #expect(c.name == "New Connection")

        c.host = "192.168.50.6"
        c.hostDidChange()
        #expect(c.name == "192.168.50.6")

        c.host = "pve.lan"
        c.hostDidChange()
        #expect(c.name == "pve.lan")
    }

    @Test func clearingTheHostGoesBackToThePlaceholder() {
        var c = SavedConnection(name: SavedConnection.placeholderName, nameIsCustom: false, host: "pve.lan")
        c.host = ""
        c.hostDidChange()
        #expect(c.name == "New Connection")
    }

    @Test func aNamedConnectionIgnoresTheHost() {
        var c = SavedConnection(name: SavedConnection.placeholderName, nameIsCustom: false, host: "")
        c.rename(to: "win11-desk")
        c.host = "192.168.50.6"
        c.hostDidChange()
        #expect(c.name == "win11-desk")
    }

    // MARK: Renaming

    @Test func renamingTrimsAndSticks() {
        var c = SavedConnection(name: "old", nameIsCustom: false, host: "pve.lan")
        c.rename(to: "  win11-desk  ")
        #expect(c.name == "win11-desk")
        #expect(c.hasCustomName)
    }

    /// Emptying the field is a way to say "go back to following the host", not an error to reject.
    @Test func anEmptiedNameHandsTheNameBackToTheHost() {
        var c = SavedConnection(name: "win11-desk", nameIsCustom: true, host: "pve.lan")
        c.rename(to: "   ")
        #expect(c.name == "pve.lan")
        #expect(!c.hasCustomName)

        c.host = "10.0.0.4"
        c.hostDidChange()
        #expect(c.name == "10.0.0.4")
    }

    // MARK: Where names come from

    @Test func aDuplicateKeepsItsOwnName() {
        let store = ConnectionStore(connections: [
            SavedConnection(name: "win11-desk", nameIsCustom: true, host: "192.168.1.20"),
        ])
        store.duplicate(store.connections[0])
        let copy = store.connections[1]
        #expect(copy.name == "win11-desk copy")
        #expect(copy.hasCustomName)

        // A copy must not be dragged back to the host by a later edit.
        var edited = copy
        edited.host = "other.lan"
        edited.hostDidChange()
        #expect(edited.name == "win11-desk copy")
    }

    @Test func addStartsUnnamed() {
        let store = ConnectionStore(connections: [])
        store.add()
        #expect(store.connections[0].name == "New Connection")
        #expect(!store.connections[0].hasCustomName)
    }

    // MARK: Stores written before renaming existed

    /// `ConnectionStore` decodes with `try?`, so a row it cannot read is a row the user loses.
    /// Synthesised `Codable` throws on a missing key even when the property has a default value,
    /// which is why `nameIsCustom` is optional. This is the test that says so.
    @Test func aStoreWrittenBeforeRenamingStillDecodes() throws {
        // Verbatim from a real connections.json written before any of this existed.
        let legacy = """
        [{"host":"192.168.50.6","id":"50D16CDB-2B01-4330-8228-35F356C7BC23",
          "savePasswordInKeychain":false,"name":"New Connection","port":5930,
          "advanced":{"hiDPI":false,"commandMapsTo":"super","optionMapsTo":"alt",
                      "releaseChord":{"modifiers":["control","option"]}},
          "agentWasPresent":false}]
        """
        let rows = try JSONDecoder().decode([SavedConnection].self, from: Data(legacy.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].name == "New Connection")
        #expect(rows[0].host == "192.168.50.6")
        #expect(rows[0].nameIsCustom == nil)
        #expect(rows[0].isSingleUse == nil)
    }

    /// A legacy row still called "New Connection" was plainly never named, so it should start
    /// following the host rather than sitting there as a placeholder forever.
    @Test func aLegacyPlaceholderRowStartsFollowingTheHost() {
        var c = SavedConnection(name: SavedConnection.placeholderName, host: "192.168.50.6")
        #expect(!c.hasCustomName)
        c.hostDidChange()
        #expect(c.name == "192.168.50.6")
    }

    /// Loading is where an unnamed row gets its name, not just editing: a store saved with the
    /// placeholder must come back named after its host.
    @Test func loadingNamesAPlaceholderRowAfterItsHost() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rows = [SavedConnection(name: SavedConnection.placeholderName, nameIsCustom: false, host: "192.168.50.6"),
                    SavedConnection(name: "win11-desk", nameIsCustom: true, host: "192.168.1.20")]
        let file = dir.appendingPathComponent("connections.json")
        try JSONEncoder().encode(rows).write(to: file)

        let loaded = try JSONDecoder().decode([SavedConnection].self, from: Data(contentsOf: file))
            .map { var c = $0; c.hostDidChange(); return c }
        #expect(loaded[0].name == "192.168.50.6")
        #expect(loaded[1].name == "win11-desk")
    }

    /// Any other legacy name is the user's, even though the flag is absent — never overwrite it.
    @Test func aLegacyNamedRowIsLeftAlone() {
        var c = SavedConnection(name: "win11-desk", host: "192.168.1.20")
        #expect(c.hasCustomName)
        c.host = "somewhere.else"
        c.hostDidChange()
        #expect(c.name == "win11-desk")
    }

    // MARK: .vv imports

    @Test func aTitledVVFileIsConsideredNamed() {
        let vv = VVFile(host: "pve.lan", port: nil, tlsPort: 61000, password: nil,
                        hostSubject: nil, caPEM: nil, title: "VM 100 - win11", deleteAfterConnecting: false)
        var c = SavedConnection(vv: vv, name: VVOpener.cleanTitle(vv.title ?? ""))
        #expect(c.name == "VM 100 - win11")
        #expect(c.hasCustomName)
        c.host = "other.lan"
        c.hostDidChange()
        #expect(c.name == "VM 100 - win11")
    }

    @Test func anUntitledVVFileKeepsFollowingItsHost() {
        let vv = VVFile(host: "pve.lan", port: nil, tlsPort: 61000, password: nil,
                        hostSubject: nil, caPEM: nil, title: nil, deleteAfterConnecting: false)
        var c = SavedConnection(vv: vv, name: vv.host)
        #expect(!c.hasCustomName)
        c.host = "other.lan"
        c.hostDidChange()
        #expect(c.name == "other.lan")
    }

    // MARK: Single-use rows

    /// A Proxmox console file is spent once its session ends: the ticket is one-shot and the host is
    /// an opaque token only the proxy can resolve. The proxy is what marks the row as single-use.
    @Test func aProxmoxVVFileMakesASingleUseConnection() {
        let vv = VVFile(host: "pvespiceproxy:abc:100:pve::deadbeef", port: nil, tlsPort: 61000, password: "ticket",
                        hostSubject: nil, caPEM: nil, title: "VM 100 - win11", deleteAfterConnecting: true,
                        proxy: HTTPConnectProxy(host: "pve.lan", port: 3128))
        let c = SavedConnection(vv: vv, name: "win11")
        #expect(c.isSingleUse == true)
    }

    @Test func aVVFileWithoutAProxyIsReusable() {
        let vv = VVFile(host: "qemu.lan", port: 5900, tlsPort: nil, password: nil,
                        hostSubject: nil, caPEM: nil, title: nil, deleteAfterConnecting: false)
        let c = SavedConnection(vv: vv, name: vv.host)
        #expect(c.isSingleUse != true)
    }
}
