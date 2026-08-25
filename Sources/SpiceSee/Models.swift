import Foundation

/// A host the user has saved in the connection manager.
struct SavedConnection: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
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
}
