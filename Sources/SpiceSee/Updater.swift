import Foundation
import Sparkle

/// The updater's only policy input: which appcast channels to consider.
///
/// Stateless on purpose. Sparkle calls this off the main actor's protection (it is a plain
/// Objective-C delegate), so it reads the persisted setting straight from user defaults rather
/// than touching `AppSettings`.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Sparkle always checks the default channel; "beta" is opt-in.
    static func channels(prereleases: Bool) -> Set<String> {
        prereleases ? ["beta"] : []
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.channels(prereleases: UserDefaults.standard.bool(forKey: "includePrereleases"))
    }
}
