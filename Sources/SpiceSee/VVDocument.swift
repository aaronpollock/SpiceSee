import Foundation
import os
import SpiceCore

extension SavedConnection {
    /// A connection made from a `.vv`. The ticket is deliberately not stored: Proxmox tickets expire
    /// within seconds, so a saved one is worse than none.
    /// A file that named itself has been named; one that fell back to its host has not, and should
    /// keep following the host if it is ever edited.
    init(vv: VVFile, name: String) {
        self.init(name: name, nameIsCustom: vv.title != nil, host: vv.host, port: vv.port ?? 0, tlsPort: vv.tlsPort)
        hostSubject = vv.hostSubject
        caPEM = vv.caPEM
        proxy = vv.proxy.map { "\($0.host):\($0.port)" }
        savePasswordInKeychain = false
    }
}

/// Opens a `.vv` handed to us by Finder or the Proxmox web UI: parse, connect straight away, and —
/// if the file asked for it and the user has not turned it off — delete it afterwards.
@MainActor
final class VVOpener {
    private let log = Logger(subsystem: "com.spicesee", category: "vv")

    func open(_ url: URL, store: ConnectionStore, session: SessionModel, settings: AppSettings) {
        let vv: VVFile
        do {
            vv = try VVFile.parse(contentsOf: url)
        } catch {
            // The file is the user's only artefact here, so name it; the parser's reason is safe to
            // show (it never contains the ticket).
            log.error("\(url.lastPathComponent, privacy: .public): \(String(describing: error))")
            session.presentFailure(.other(
                title: "That file isn't a SPICE connection",
                message: "SpiceSee could not read \(url.lastPathComponent). Download a fresh console file from the web UI."))
            return
        }

        let name = vv.title.map(Self.cleanTitle) ?? vv.host
        var connection = SavedConnection(vv: vv, name: name)
        connection.lastConnected = Date()
        // Connect with the row the store actually holds: a refreshed row keeps its own id and name,
        // and the manager matches a running session to a sidebar row by id.
        session.connect(store.addImported(connection), password: vv.password)

        // Deleted the moment the connect is kicked off, not when it succeeds: the single-use ticket
        // inside is spent either way, so waiting for a result would only leave the file behind on
        // every failure.
        if vv.deleteAfterConnecting, settings.deleteVVAfterConnecting {
            do { try FileManager.default.removeItem(at: url) }
            catch { log.notice("could not delete \(url.lastPathComponent, privacy: .public)") }
        }
    }

    /// Proxmox titles carry a virt-viewer hint: "VM 100 - win11 (Press %s to release the cursor)".
    static func cleanTitle(_ title: String) -> String {
        guard let paren = title.range(of: " (Press %s") else { return title }
        return String(title[title.startIndex ..< paren.lowerBound])
    }
}
