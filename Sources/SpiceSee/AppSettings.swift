import Foundation
import Observation

/// Global defaults. Per-connection Advanced settings override these.
@MainActor @Observable
final class AppSettings {
    var defaultScaling: ScalingMode = .fit
    var hiDPIByDefault = false
    var openWindowPerMonitor = true
    var syncClipboardWhenAgentAvailable = true
    var deleteVVAfterConnecting = true
    /// A Proxmox row is spent once its session ends; on, it goes without asking.
    var removeSingleUseOnDisconnect = false

    var commandMapsTo: GuestModifier = .super
    var optionMapsTo: GuestModifier = .alt
    var releaseChord: ReleaseChord = .controlOption
    var sendLockKeys = true

    var checkForUpdatesAutomatically = true
    var installInBackground = false
    var includePrereleases = false
    var lastUpdateCheck: Date?

    private let defaults = UserDefaults.standard

    init() { load() }

    private func load() {
        if let raw = defaults.string(forKey: "defaultScaling"), let v = ScalingMode(rawValue: raw) { defaultScaling = v }
        hiDPIByDefault = defaults.bool(forKey: "hiDPIByDefault")
        openWindowPerMonitor = defaults.object(forKey: "openWindowPerMonitor") as? Bool ?? true
        syncClipboardWhenAgentAvailable = defaults.object(forKey: "syncClipboard") as? Bool ?? true
        deleteVVAfterConnecting = defaults.object(forKey: "deleteVV") as? Bool ?? true
        removeSingleUseOnDisconnect = defaults.bool(forKey: "removeSingleUseOnDisconnect")
        sendLockKeys = defaults.object(forKey: "sendLockKeys") as? Bool ?? true
        checkForUpdatesAutomatically = defaults.object(forKey: "autoUpdate") as? Bool ?? true
    }

    func save() {
        defaults.set(defaultScaling.rawValue, forKey: "defaultScaling")
        defaults.set(hiDPIByDefault, forKey: "hiDPIByDefault")
        defaults.set(openWindowPerMonitor, forKey: "openWindowPerMonitor")
        defaults.set(syncClipboardWhenAgentAvailable, forKey: "syncClipboard")
        defaults.set(deleteVVAfterConnecting, forKey: "deleteVV")
        defaults.set(removeSingleUseOnDisconnect, forKey: "removeSingleUseOnDisconnect")
        defaults.set(sendLockKeys, forKey: "sendLockKeys")
        defaults.set(checkForUpdatesAutomatically, forKey: "autoUpdate")
    }

    /// "SpiceSee 1.0 (build 142) · last checked today at 08:57"
    var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        guard let lastUpdateCheck else { return "SpiceSee \(version) (build \(build))" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let when = Calendar.current.isDateInToday(lastUpdateCheck) ? "today at \(f.string(from: lastUpdateCheck))" : f.string(from: lastUpdateCheck)
        return "SpiceSee \(version) (build \(build)) · last checked \(when)"
    }
}
