import Foundation

/// A host the user has saved in the connection manager.
struct SavedConnection: Identifiable, Hashable, Codable {
    /// What a connection is called before anyone names it.
    static let placeholderName = "New Connection"

    var id = UUID()
    /// The sidebar row title and the detail pane's heading. Editable in place; until it is edited it
    /// follows the host.
    var name: String
    /// Whether the user named this connection themselves.
    ///
    /// `Optional` is load-bearing, not laziness: synthesised `Codable` decoding throws on a missing
    /// key **even when the property has a default value**, and `ConnectionStore` decodes with `try?`
    /// — so a non-optional field added here would silently empty everyone's saved connections on the
    /// next launch. Absent means "leave the name alone", except for a row still carrying the
    /// placeholder, which has plainly never been named.
    var nameIsCustom: Bool?
    var host: String
    var port: UInt16 = 5900
    var tlsPort: UInt16?
    var savePasswordInKeychain: Bool = true
    var lastConnected: Date?
    /// Whether spice-vdagent was present the last time we connected — shown in the detail footer.
    var agentWasPresent: Bool = false
    var advanced = AdvancedSettings()
    /// From a `.vv`: the certificate subject the server must present, and the CA that signs it.
    /// Persisted so a saved Proxmox connection still verifies on the next launch.
    var hostSubject: String?
    var caPEM: String?

    var endpoint: String { "\(host):\(tlsPort ?? port)" }
    var usesTLS: Bool { tlsPort != nil }

    var hasCustomName: Bool { nameIsCustom ?? (name != Self.placeholderName) }

    /// What an unnamed connection is called: the host, as soon as there is one.
    var derivedName: String { host.isEmpty ? Self.placeholderName : host }

    /// Renames from the UI. Emptying the field is not an error — it hands the name back to the host.
    mutating func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        nameIsCustom = !trimmed.isEmpty
        name = trimmed.isEmpty ? derivedName : trimmed
    }

    /// Keeps an unnamed connection's name in step with the host as it is typed.
    mutating func hostDidChange() {
        guard !hasCustomName else { return }
        name = derivedName
    }
}

/// Per-connection overrides of the global defaults.
struct AdvancedSettings: Hashable, Codable {
    var hiDPI: Bool = false
    var commandMapsTo: GuestModifier = .super
    var optionMapsTo: GuestModifier = .alt
    var releaseChord: ReleaseChord = .controlOption
}

enum GuestModifier: String, CaseIterable, Codable, Identifiable {
    case `super`, ctrl, alt
    var id: String { rawValue }
    var label: String {
        switch self {
        case .super: "Super"
        case .ctrl: "Ctrl"
        case .alt: "Alt"
        }
    }
}

/// The chord that releases a captured pointer in server mode. Two modifiers minimum.
struct ReleaseChord: Hashable, Codable {
    var modifiers: Set<ChordModifier>
    static let controlOption = ReleaseChord(modifiers: [.control, .option])
    var isValid: Bool { modifiers.count >= 2 }
    /// Glyphs in the canonical macOS order, e.g. "⌃⌥".
    var display: String { ChordModifier.allCases.filter { modifiers.contains($0) }.map(\.glyph).joined() }
}

enum ChordModifier: String, CaseIterable, Codable, Identifiable {
    case control, option, shift, command
    var id: String { rawValue }
    var glyph: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }
}

enum ScalingMode: String, CaseIterable, Identifiable, Codable {
    case fit, oneToOne
    var id: String { rawValue }
    var label: String { self == .fit ? "Fit" : "1:1" }
    var settingsLabel: String { self == .fit ? "Fit window" : "1:1 pixels" }
}

/// vdagent liveness. Drives the toolbar chip and which features are offered.
enum AgentState: Equatable {
    case connected
    case negotiating
    case absent

    var label: String {
        switch self {
        case .connected, .negotiating: "Agent"
        case .absent: "No agent"
        }
    }

    var tooltip: String {
        switch self {
        case .connected:
            "Connected — clipboard sync, resize-follows-window, absolute pointer"
        case .negotiating:
            "Negotiating — agent tokens not yet granted; resolves within ~1 s of MAIN_INIT"
        case .absent:
            "spice-vdagent isn't running in the guest. Clipboard sync and resize-follows-window are unavailable, and the pointer is captured while you work — press ⌃⌥ to release it."
        }
    }
}

/// Bring-up steps, mirroring SpiceCore. Shown inline in the detail pane, never as a modal.
enum ConnectStep: Int, CaseIterable, Identifiable {
    case tls, ticket, channels
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .tls: "TLS handshake · host-subject verified"
        case .ticket: "Ticket accepted · main channel linked"
        case .channels: "Opening display, inputs, cursor, playback channels…"
        }
    }
}

/// Plain-language failures. The SPICE error code never reaches this text — it goes to the log.
enum ConnectFailure: Equatable, Identifiable {
    case hostSubjectMismatch(expected: String, presented: String, host: String)
    case refused(endpoint: String)
    case passwordRejected
    case other(title: String, message: String)

    var id: String { title }

    var title: String {
        switch self {
        case .hostSubjectMismatch: "The server's certificate doesn't match this connection"
        case let .refused(endpoint): "Nothing is listening on \(endpoint)"
        case .passwordRejected: "The password was rejected"
        case let .other(title, _): title
        }
    }

    var message: String {
        switch self {
        case .hostSubjectMismatch:
            "SpiceSee expected the certificate to be issued to the subject in your .vv file. Someone may be intercepting the connection, or the host's certificate was reissued."
        case .refused:
            "The host refused the connection. The VM may be powered off, or its SPICE console may not be enabled in Proxmox."
        case .passwordRejected:
            "Proxmox SPICE tickets expire a few seconds after they're issued. If this connection came from a .vv file, open a new console from the web UI."
        case let .other(_, message): message
        }
    }
}

/// One guest monitor. The design opens one window per viewport.
struct ViewportInfo: Identifiable, Hashable {
    var id: Int
    var index: Int
    var total: Int
    var width: Int
    var height: Int
    /// "Display 1 of 2 · 1920 × 1080"
    var subtitle: String { "Display \(index + 1) of \(total) · \(width) × \(height)" }
    /// Window-menu entry, so a display closed by mistake can be brought back.
    var menuTitle: String { "Display \(index + 1) — \(width) × \(height)" }
}

/// A VM whose console moved mid-session (MAIN_MIGRATE_SWITCH_HOST).
struct MigrationOffer: Equatable {
    var vmName: String
    var newHost: String
    var newPort: UInt16
    /// A cluster that runs its consoles over TLS advertises the secure port here; the reconnect
    /// must use it rather than dropping to `newPort`.
    var newTLSPort: UInt16?
    /// The certificate subject the new host will present — it differs from the old one, since the
    /// subject names the node the VM moved to.
    var certSubject: String?
}
