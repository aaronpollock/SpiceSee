import Foundation
import Testing
@testable import SpiceSee

@MainActor
@Suite struct UpdaterTests {
    private let defaults = UserDefaults.standard

    /// Sparkle checks the default (unnamed) channel always; "beta" is opt-in.
    @Test func prereleasesOptIntoTheBetaChannel() {
        #expect(UpdaterDelegate.channels(prereleases: true) == ["beta"])
        #expect(UpdaterDelegate.channels(prereleases: false).isEmpty)
    }

    /// The delegate reads the same key AppSettings writes, so the pane's toggle is what it answers.
    @Test func includePrereleasesRoundTripsThroughDefaults() {
        let before = defaults.object(forKey: "includePrereleases")
        defer { restore(before, forKey: "includePrereleases") }

        let settings = AppSettings()
        settings.includePrereleases = true
        settings.save()
        #expect(AppSettings().includePrereleases)
        #expect(defaults.bool(forKey: "includePrereleases"))

        settings.includePrereleases = false
        settings.save()
        #expect(!AppSettings().includePrereleases)
    }

    /// Automatic checks and background installs are Sparkle's to persist now; our defaults must
    /// not keep a stale shadow copy of them.
    @Test func sparkleOwnedKeysAreNoLongerWritten() {
        let autoBefore = defaults.object(forKey: "autoUpdate")
        defer { restore(autoBefore, forKey: "autoUpdate") }
        defaults.removeObject(forKey: "autoUpdate")

        AppSettings().save()
        #expect(defaults.object(forKey: "autoUpdate") == nil)
    }

    @Test func versionSummaryReportsTheLastCheck() {
        let summary = AppSettings().versionSummary(lastChecked: nil)
        #expect(summary.hasPrefix("SpiceSee "))
        #expect(!summary.contains("last checked"))
        let today = Calendar.current.date(bySettingHour: 8, minute: 57, second: 0, of: Date())!
        #expect(AppSettings().versionSummary(lastChecked: today).hasSuffix("last checked today at 08:57"))
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
