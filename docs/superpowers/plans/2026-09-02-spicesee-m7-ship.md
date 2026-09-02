# SpiceSee M7 — Ship Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command on this Mac produces a notarized, stapled `SpiceSee-1.0.0.dmg` plus a signed Sparkle `appcast.xml` in `dist/`, ready to upload to https://somecoolthings.com/spicesee, from an app whose acknowledgements window tells the truth.

**Architecture:** Sparkle 2 arrives as an SPM binary package; one `SPUStandardUpdaterController` lives in `SpiceSeeApp`, a stateless `UpdaterDelegate` answers the beta channel from user defaults, and the existing Updates pane writes through to the updater's own persisted properties. `scripts/release.sh` is the whole release pipeline: archive with Developer ID on the command line (the project stays ad hoc for development), export, notarize the app then the DMG, staple both, verify, and run `generate_appcast`. The build number is the git commit count passed at archive time, so a development build is visibly build 0.

**Tech Stack:** xcodegen + xcodebuild archive/export, `notarytool`, `stapler`, `hdiutil`, Sparkle 2.9.x (SPM, `generate_keys` / `generate_appcast` from the package's `bin/`), Swift 6 strict concurrency, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-spicesee-m7-ship-design.md`. Two small additions found while planning: `SUEnableAutomaticChecks` is set in `Info.plist` so Sparkle does not raise its own "check automatically?" dialog beside our toggle, and `AppSettings.includePrereleases` — never persisted until now — is saved under the key `includePrereleases`, which is the key the delegate reads. The spec's "disabled while `canCheckForUpdates` is false" on the menu item is dropped: it needs KVO→main-actor plumbing for a state Sparkle already guards internally, and `checkForUpdates()` during a check is harmless.

## Global Constraints

- Swift 6 language mode, strict concurrency, macOS 14 deployment target, **arm64 only**. No locks, no `@unchecked Sendable`, no `nonisolated(unsafe)`.
- `project.yml` keeps `CODE_SIGN_IDENTITY: "-"` and no `DEVELOPMENT_TEAM`; signing identity, team and `CURRENT_PROJECT_VERSION` are passed on the archive command line only. **Nothing about signing is committed.** The private EdDSA key never enters the repo; the notary keychain profile is named `notary`.
- Team id `HBHQCPQ22A`. Feed URL `https://somecoolthings.com/spicesee/appcast.xml`. Download prefix `https://somecoolthings.com/spicesee/`. Marketing version `1.0.0`. Build = `git rev-list --count HEAD`.
- Entitlements stay exactly `com.apple.security.network.client` and `com.apple.security.cs.disable-library-validation`. `CSpiceCodec.framework` stays an embedded dynamic framework; `scripts/check-vendored-notices.sh` must exit 0 before any release.
- Chili red is the accent only; no new UI chrome. The Updates pane's layout does not change — only what its controls are bound to.
- The `SessionBackend` seam and the engine are untouched. No `print` outside executables; library code logs via `os.Logger(subsystem: "com.spicesee", category:)`.
- Conventional commits (`feat:`, `fix:`, `build:`, `docs:`, `chore:`). Every commit ends with `Claude-Session: https://claude.ai/code/session_013BE2VqTBYVubDjeDPiuUAC`.
- After adding or removing files under `Sources/SpiceSee/` or `Tests/SpiceSeeTests/`, or editing `project.yml`: `xcodegen generate`, then build the `SpiceSee` scheme once, then run the app tests:
  ```bash
  xcodegen generate
  xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
  xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "^(✘|✔ Test run)|error:"
  ```
  `swift test` never sees `Sources/SpiceSee`; it must still pass (`swift test 2>&1 | tail -3`).
- `Sources/SpiceSee/Info.plist` is **generated** by xcodegen from `project.yml`'s `info:` block and is committed. Edit `project.yml`, run `xcodegen generate`, commit both.

## File Structure

| Path | Responsibility |
|---|---|
| `Sources/SpiceSee/AcknowledgementsView.swift` (modify) | Component list minus libopus; real source URL; licence loader takes a bundle |
| `Sources/SpiceSee/Licenses/MIT.txt` (replace) | Sparkle's actual MIT text |
| `Tests/SpiceSeeTests/AcknowledgementsTests.swift` (create) | Pins the component list, the source URL, and that every licence file ships and is not a template |
| `project.yml` (modify) | Sparkle package; version keys; `LSApplicationCategoryType`; `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`; Licenses as test resources |
| `Sources/SpiceSee/Info.plist` (regenerated) | Output of the above |
| `Sources/SpiceSee/Updater.swift` (create) | `UpdaterDelegate` — `allowedChannels(for:)` and the pure `channels(prereleases:)` it calls |
| `Sources/SpiceSee/AppSettings.swift` (modify) | Drop the two keys Sparkle owns; persist `includePrereleases`; `versionSummary(lastChecked:)` |
| `Sources/SpiceSee/SettingsView.swift` (modify) | `UpdatesPane` bound to `SPUUpdater`; `SettingsView` takes the updater |
| `Sources/SpiceSee/SpiceSeeApp.swift` (modify) | Owns `SPUStandardUpdaterController`; "Check for Updates…" menu item |
| `Tests/SpiceSeeTests/UpdaterTests.swift` (create) | Channel rule; `includePrereleases` round trip; Sparkle-owned keys no longer written |
| `scripts/release.sh` (create), `scripts/ExportOptions.plist` (create) | The release pipeline |
| `.gitignore` (modify) | `dist/`, `build/` |
| `docs/replacing-the-codec.md` (create) | LGPL-2.1 §6(b) record |
| `docs/superpowers/specs/2026-08-22-spicesee-design.md` (modify §8, M7 row) | Corrected distribution facts |
| `docs/dev-server.md` (append `## M7 exit check (manual)`) | The user's checklist and the notarization answer |
| `docs/release-todo.md` (delete), `CLAUDE.md` (modify) | Backlog closed; status paragraph updated |

---

### Task 1: Make the acknowledgements window true

**Files:**
- Modify: `Sources/SpiceSee/AcknowledgementsView.swift:1-70`
- Replace: `Sources/SpiceSee/Licenses/MIT.txt`
- Modify: `project.yml` (SpiceSeeTests target gets the Licenses resources)
- Create: `Tests/SpiceSeeTests/AcknowledgementsTests.swift`

**Interfaces:**
- Produces: `AcknowledgementComponent` (internal, was private), `acknowledgementsSourceURL` (internal), `loadLicenseText(fileName:in:) -> String?` (internal; `in` defaults to `.main`). Task 6 relies on the callout text in this file; Task 4 relies on the Sparkle entry staying.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SpiceSeeTests/AcknowledgementsTests.swift`:

```swift
import Foundation
import Testing
@testable import SpiceSee

/// The acknowledgements window is the LGPL written offer and the credits; it must describe the
/// bundle that ships, not the one that was planned.
@Suite struct AcknowledgementsTests {
    /// `Bundle(for:)` needs a class; the test bundle carries the licence files as resources.
    private final class Marker {}

    /// M6 decodes Opus through AudioToolbox; libopus is only the fixture generator and never ships.
    @Test func libopusIsNotCredited() {
        #expect(!AcknowledgementComponent.all.contains { $0.id == "libopus" })
        #expect(AcknowledgementComponent.all.contains { $0.id == "sparkle" })
    }

    @Test func everyLicenceFileShipsAndIsNotATemplate() {
        let bundle = Bundle(for: Marker.self)
        for component in AcknowledgementComponent.all {
            let text = loadLicenseText(fileName: component.licenseFileName, in: bundle)
            #expect(text != nil, "\(component.licenseFileName).txt missing from the bundle")
            #expect(text?.contains("<year>") == false, "\(component.licenseFileName).txt is still the template")
            #expect(text?.contains("PLACEHOLDER") == false)
        }
    }

    @Test func theSourceLinkIsTheRealRepository() {
        #expect(acknowledgementsSourceURL.absoluteString == "https://github.com/aaronpollock/SpiceSee")
    }
}
```

- [ ] **Step 2: Add the Licenses resources to the test target**

In `project.yml`, the `SpiceSeeTests` target's `sources:` currently reads:

```yaml
    sources:
      - path: Tests/SpiceSeeTests
      - path: Sources/SpiceSee
        excludes: [Licenses, Assets.xcassets, Info.plist, SpiceSee.entitlements]
```

Make it:

```yaml
    sources:
      - path: Tests/SpiceSeeTests
      - path: Sources/SpiceSee
        excludes: [Licenses, Assets.xcassets, Info.plist, SpiceSee.entitlements]
      - path: Sources/SpiceSee/Licenses
        buildPhase: resources
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test -only-testing:SpiceSeeTests/AcknowledgementsTests 2>&1 | grep -E "error:|^(✘|✔)"
```

Expected: compile errors — `'AcknowledgementComponent' is inaccessible due to 'private'`, `loadLicenseText` has no `in:` parameter, `acknowledgementsSourceURL` inaccessible.

- [ ] **Step 4: Change the component list, the URL, and the loader**

In `Sources/SpiceSee/AcknowledgementsView.swift`:

1. `private struct AcknowledgementComponent` → `struct AcknowledgementComponent`.
2. Delete the whole `libopus` element of `all` (the `AcknowledgementComponent(id: "libopus", …)` literal).
3. Replace the URL and loader block (from `// TODO(release)` through the end of `loadLicenseText`) with:

```swift
/// Public repository, which is what the LGPL written offer in the framework callout points at.
let acknowledgementsSourceURL = URL(string: "https://github.com/aaronpollock/SpiceSee")!

/// The build flattens Sources/SpiceSee/Licenses into Resources/, so the subdirectory lookup
/// misses; fall back to the bundle root rather than shipping without the licence text.
/// `bundle` is a parameter so the test bundle can check its own copy of the resources.
func loadLicenseText(fileName: String, in bundle: Bundle = .main) -> String? {
    let url = bundle.url(forResource: fileName, withExtension: "txt", subdirectory: "Licenses")
        ?? bundle.url(forResource: fileName, withExtension: "txt")
    guard let url else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
}
```

The `placeholderLicenseText` constant and its guard are gone with this replacement. Check nothing else referenced it: `grep -n placeholderLicenseText Sources/SpiceSee/*.swift` prints nothing.

- [ ] **Step 5: Replace MIT.txt with Sparkle's licence**

Overwrite `Sources/SpiceSee/Licenses/MIT.txt` with the upstream file:

```bash
curl -sSfL https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/LICENSE -o Sources/SpiceSee/Licenses/MIT.txt
head -3 Sources/SpiceSee/Licenses/MIT.txt
```

Expected first line: `Copyright (c) 2006-2013 Andy Matuschak.` If the fetch fails, the file is the MIT text with these copyright lines in place of the template's `<year> <copyright holders>` line: Andy Matuschak 2006-2013, Elgato Systems GmbH 2009-2013, Kornel Lesiński 2011-2014, Mayur Pawashe 2015-2017, C.W. Betts 2014, Petroules Corporation 2014, Big Nerd Ranch 2014, then `All rights reserved.` and the standard MIT permission paragraphs.

- [ ] **Step 6: Run the tests to verify they pass**

Same three commands as Step 3, then the whole bundle:

```bash
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "^(✘|✔ Test run)|error:"
```

Expected: `✔ Test run with N tests … passed`, no `✘`.

- [ ] **Step 7: Commit**

```bash
git add Sources/SpiceSee/AcknowledgementsView.swift Sources/SpiceSee/Licenses/MIT.txt project.yml Tests/SpiceSeeTests/AcknowledgementsTests.swift
git commit -m "fix: the acknowledgements window credits what ships

libopus never ships — M6 decodes Opus through AudioToolbox and libopus only
generates a test fixture. MIT.txt is now Sparkle's licence, not a template,
and the written-offer link points at the public repository.

Claude-Session: https://claude.ai/code/session_013BE2VqTBYVubDjeDPiuUAC"
```

---

### Task 2: Version scheme and app category

**Files:**
- Modify: `project.yml` (`info.properties`, `settings.base`)
- Regenerated: `Sources/SpiceSee/Info.plist`

**Interfaces:**
- Produces: build settings `MARKETING_VERSION=1.0.0`, `CURRENT_PROJECT_VERSION=0` (overridden at archive time by Task 5's script). `AppSettings.versionSummary` keeps reading `CFBundleShortVersionString` / `CFBundleVersion`.

- [ ] **Step 1: Edit `project.yml`**

In `targets.SpiceSee.info.properties`, replace

```yaml
        CFBundleShortVersionString: "1.0"
        CFBundleVersion: "142"
```

with

```yaml
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        LSApplicationCategoryType: public.app-category.utilities
```

In `targets.SpiceSee.settings.base`, replace `MARKETING_VERSION: "1.0"` with:

```yaml
        MARKETING_VERSION: "1.0.0"
        # The release script passes the git commit count; a development build is visibly build 0.
        CURRENT_PROJECT_VERSION: "0"
```

- [ ] **Step 2: Regenerate and verify the plist and a built app**

```bash
xcodegen generate
grep -A1 -E "CFBundleShortVersionString|CFBundleVersion|LSApplicationCategoryType" Sources/SpiceSee/Info.plist
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP=$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/SpiceSee.app
defaults read "$APP/Contents/Info" CFBundleShortVersionString; defaults read "$APP/Contents/Info" CFBundleVersion
```

Expected: the plist holds the `$(…)` references and the category; the built app reports `1.0.0` and `0`.

- [ ] **Step 3: Run the app tests (they read the plist through `versionSummary` previews only, but stay green)**

```bash
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "^(✘|✔ Test run)|error:"
```

- [ ] **Step 4: Commit**

```bash
git add project.yml Sources/SpiceSee/Info.plist
git commit -m "build: 1.0.0, build number from CURRENT_PROJECT_VERSION, utilities category

The release script passes the git commit count as CURRENT_PROJECT_VERSION;
a development build reports build 0, so it can never be mistaken for a release.

Claude-Session: https://claude.ai/code/session_013BE2VqTBYVubDjeDPiuUAC"
```

---

### Task 3: Sparkle dependency, `UpdaterDelegate`, and the settings it needs

**Files:**
- Modify: `project.yml` (`packages`, SpiceSee and SpiceSeeTests dependencies)
- Create: `Sources/SpiceSee/Updater.swift`
- Modify: `Sources/SpiceSee/AppSettings.swift`
- Create: `Tests/SpiceSeeTests/UpdaterTests.swift`

**Interfaces:**
- Produces: `final class UpdaterDelegate: NSObject, SPUUpdaterDelegate` with `static func channels(prereleases: Bool) -> Set<String>` and `func allowedChannels(for updater: SPUUpdater) -> Set<String>`; `AppSettings.includePrereleases` persisted under the defaults key `"includePrereleases"`; `AppSettings.versionSummary(lastChecked: Date?) -> String`. `AppSettings.checkForUpdatesAutomatically`, `installInBackground` and `lastUpdateCheck` are removed — Task 4 must not reference them.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SpiceSeeTests/UpdaterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test -only-testing:SpiceSeeTests/UpdaterTests 2>&1 | grep -E "error:|^(✘|✔)"
```

Expected: `cannot find 'UpdaterDelegate' in scope`; `versionSummary` "cannot call value of non-function type".

- [ ] **Step 3: Add the Sparkle package**

In `project.yml`, `packages:` becomes:

```yaml
packages:
  SpiceSee:
    path: .
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.9.6"
```

Add `- package: Sparkle` to the `dependencies:` list of **both** the `SpiceSee` target and the `SpiceSeeTests` target (the test bundle compiles the app sources into itself, so it links Sparkle too).

- [ ] **Step 4: Write `UpdaterDelegate`**

Create `Sources/SpiceSee/Updater.swift`:

```swift
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
```

- [ ] **Step 5: Change `AppSettings`**

In `Sources/SpiceSee/AppSettings.swift`:

Replace

```swift
    var checkForUpdatesAutomatically = true
    var installInBackground = false
    var includePrereleases = false
    var lastUpdateCheck: Date?
```

with

```swift
    /// Sparkle persists automatic-check and background-install itself; this is the one updater
    /// setting that is ours, read back by `UpdaterDelegate` under the same key it is saved under.
    var includePrereleases = false
```

In `load()`, replace `checkForUpdatesAutomatically = defaults.object(forKey: "autoUpdate") as? Bool ?? true` with:

```swift
        includePrereleases = defaults.bool(forKey: "includePrereleases")
```

In `save()`, replace `defaults.set(checkForUpdatesAutomatically, forKey: "autoUpdate")` with:

```swift
        defaults.set(includePrereleases, forKey: "includePrereleases")
```

Replace the `versionSummary` computed property with a function; the date now comes from Sparkle:

```swift
    /// "SpiceSee 1.0.0 (build 142) · last checked today at 08:57"
    func versionSummary(lastChecked: Date?) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        guard let lastChecked else { return "SpiceSee \(version) (build \(build))" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let when = Calendar.current.isDateInToday(lastChecked) ? "today at \(f.string(from: lastChecked))" : f.string(from: lastChecked)
        return "SpiceSee \(version) (build \(build)) · last checked \(when)"
    }
```

- [ ] **Step 6: Build; expect exactly one failure in `SettingsView.swift`**

```bash
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: errors only in `SettingsView.swift` (`UpdatesPane` references the removed properties). Package resolution must succeed — if it prints `Sparkle` resolution errors, check network and the `from:` version. Fix the pane minimally now so the build is green and Task 4 can start from a compiling tree: in `UpdatesPane`, temporarily replace the three toggles' bindings and the version text with:

```swift
            Toggle("Check for updates automatically", isOn: .constant(true))
            VStack(alignment: .leading, spacing: Metric.Settings.rowRhythm) {
                Toggle("Download and install in the background", isOn: .constant(false))
                Toggle("Include pre-release builds", isOn: settings.binding(\.includePrereleases))
            }
            .padding(.leading, 20)
            Spacer(minLength: 0)
            HStack {
                Text(settings.versionSummary(lastChecked: nil))
```

Task 4 replaces the two `.constant` bindings. Rebuild: `BUILD SUCCEEDED`.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "^(✘|✔ Test run)|error:"
swift test 2>&1 | tail -3
```

Expected: all app tests pass including the four new ones; `swift test` unchanged and green.

- [ ] **Step 8: Commit**

```bash
git add project.yml Sources/SpiceSee/Updater.swift Sources/SpiceSee/AppSettings.swift Sources/SpiceSee/SettingsView.swift Tests/SpiceSeeTests/UpdaterTests.swift
git commit -m "feat: Sparkle dependency, beta-channel delegate, pre-release setting persisted

Automatic checks and background installs are Sparkle's own persisted
properties now; includePrereleases is ours and is read back by the delegate
under the key it is saved under.

Claude-Session: https://claude.ai/code/session_013BE2VqTBYVubDjeDPiuUAC"
```

---

### Task 4: Wire the updater into the app, the Updates pane and the menu

**Files:**
- Modify: `Sources/SpiceSee/SpiceSeeApp.swift`
- Modify: `Sources/SpiceSee/SettingsView.swift` (`SettingsView`, `UpdatesPane`, previews)
- Modify: `project.yml` (`info.properties`: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`)
- Regenerated: `Sources/SpiceSee/Info.plist`

**Interfaces:**
- Consumes: `UpdaterDelegate`, `AppSettings.includePrereleases`, `AppSettings.versionSummary(lastChecked:)` from Task 3.
- Produces: `SettingsView(settings:updater:)`. `SpiceSeeApp.updaterController: SPUStandardUpdaterController`. Task 5's script requires `SUPublicEDKey` to be a real key.

This task has no unit-testable logic of its own (it binds SwiftUI controls to Sparkle's properties); its verification is the build plus a mock launch that shows the pane and the menu item.

- [ ] **Step 1: Generate the EdDSA key pair (once, on this Mac)**

The Sparkle tools arrive with the package resolution Task 3 triggered:

```bash
BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d | head -1)
"$BIN/generate_keys"
```

It stores the private key in the login keychain (it may prompt to allow keychain access — that is the user's click) and prints a line like `<key>SUPublicEDKey</key>` / `<string>…base64…</string>`. If a key already exists it prints the existing public key instead (`generate_keys -p` also does). Copy the base64 string.

- [ ] **Step 2: Add the Sparkle plist keys**

In `project.yml`, `targets.SpiceSee.info.properties`, after `LSApplicationCategoryType`:

```yaml
        SUFeedURL: https://somecoolthings.com/spicesee/appcast.xml
        SUPublicEDKey: "<paste the base64 public key here>"
        # Our Updates pane owns the automatic-check toggle; without this Sparkle also asks on first launch.
        SUEnableAutomaticChecks: true
```

- [ ] **Step 3: Own the updater in the app and add the menu item**

In `Sources/SpiceSee/SpiceSeeApp.swift`:

Add `import Sparkle` after `import SwiftUI`.

Add a stored property to `SpiceSeeApp`, after the `session` state:

```swift
    /// Started at launch so scheduled checks run; the delegate is stateless and reads defaults.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: UpdaterDelegate(), userDriverDelegate: nil)
```

Change the `Settings` scene to pass it:

```swift
        Settings {
            SettingsView(settings: settings, updater: updaterController.updater)
        }
```

In the `CommandGroup(replacing: .appInfo)` block, add the item between About and Acknowledgements:

```swift
            CommandGroup(replacing: .appInfo) {
                Button("About SpiceSee") { NSApp.orderFrontStandardAboutPanel(nil) }
                Button("Check for Updates…") { updaterController.updater.checkForUpdates() }
                Button("Acknowledgements…") { openWindow(id: "acknowledgements") }
            }
```

- [ ] **Step 4: Bind the Updates pane to the updater**

In `Sources/SpiceSee/SettingsView.swift`, add `import Sparkle` after `import SwiftUI`.

`SettingsView` gains the updater and passes it to the pane:

```swift
struct SettingsView: View {
    let settings: AppSettings
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow
    …
            UpdatesPane(settings: settings, updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.up.circle") }
                .frame(width: Metric.Window.preferences.width, height: Metric.Settings.updatesHeight)
```

Replace the whole `UpdatesPane` struct with:

```swift
/// The two automatic toggles are Sparkle's own persisted properties, mirrored into local state
/// and written back only on a user change (Sparkle's documented pattern — the updater must not be
/// poked on every render). Pre-release opt-in is ours; `UpdaterDelegate` reads it.
private struct UpdatesPane: View {
    let settings: AppSettings
    let updater: SPUUpdater
    @State private var checksAutomatically: Bool
    @State private var downloadsAutomatically: Bool

    init(settings: AppSettings, updater: SPUUpdater) {
        self.settings = settings
        self.updater = updater
        _checksAutomatically = State(initialValue: updater.automaticallyChecksForUpdates)
        _downloadsAutomatically = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.Settings.rowRhythm) {
            Toggle("Check for updates automatically", isOn: $checksAutomatically)
                .onChange(of: checksAutomatically) { _, on in updater.automaticallyChecksForUpdates = on }

            VStack(alignment: .leading, spacing: Metric.Settings.rowRhythm) {
                Toggle("Download and install in the background", isOn: $downloadsAutomatically)
                    .disabled(!checksAutomatically)
                    .onChange(of: downloadsAutomatically) { _, on in updater.automaticallyDownloadsUpdates = on }
                Toggle("Include pre-release builds", isOn: settings.binding(\.includePrereleases))
            }
            .padding(.leading, 20)

            Spacer(minLength: 0)

            HStack {
                Text(settings.versionSummary(lastChecked: updater.lastUpdateCheckDate))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
    }
}
```

Delete the old `checkNow()` with its `// Sparkle SPUUpdater lands in M7` comment. Update the preview:

```swift
#Preview("Updates") {
    UpdatesPane(settings: AppSettings(),
                updater: SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater)
        .frame(width: Metric.Window.preferences.width, height: Metric.Settings.updatesHeight)
        .preferredColorScheme(.light)
}
```

- [ ] **Step 5: Build and run the tests**

```bash
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:.*Sources/SpiceSee|BUILD (SUCCEEDED|FAILED)"
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "^(✘|✔ Test run)|error:"
```

Expected: `BUILD SUCCEEDED`, no new warnings, all tests pass. If the compiler reports that `allowedChannels(for:)` is main-actor-isolated and cannot satisfy a nonisolated requirement, `UpdaterDelegate` has picked up isolation it must not have — it is a plain `final class`, not `@MainActor`; keep it that way. If it reports `SPUUpdater` is non-Sendable crossing an actor boundary in `SpiceSeeApp`, the `updaterController` must be a `let` on the `App` (main actor), not captured in a `Task`.

- [ ] **Step 6: Launch the mock app and check the pane and the menu statically**

```bash
BUILT=$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')
SPICESEE_MOCK=1 "$BUILT/SpiceSee.app/Contents/MacOS/SpiceSee" --scenario desktop &
sleep 3
log show --last 10s --predicate 'process == "SpiceSee" AND (eventMessage CONTAINS "Sparkle" OR subsystem CONTAINS "sparkle")' 2>/dev/null | tail -5
osascript -e 'tell application "SpiceSee" to quit'
```

Expected: the app launches with no Sparkle error in the log (a "no update check performed yet" style notice is fine; an `SUNoPublicDSAKeyError` or "updater failed to start" means the public key was not pasted). The Updates pane and the app menu cannot be clicked from here — note in the commit message that they are the user's to check.

- [ ] **Step 7: Commit**

```bash
git add project.yml Sources/SpiceSee/Info.plist Sources/SpiceSee/SpiceSeeApp.swift Sources/SpiceSee/SettingsView.swift
git commit -m "feat: Sparkle updater wired to the Updates pane and the app menu

SUFeedURL points at somecoolthings.com/spicesee/appcast.xml; the public
EdDSA key is committed, the private key stays in the keychain. The pane's
automatic toggles mirror the updater's own persisted properties.

Claude-Session: https://claude.ai/code/session_013BE2VqTBYVubDjeDPiuUAC"
```

---

### Task 5: `scripts/release.sh` — archive, sign, notarize, DMG, appcast

**Files:**
- Create: `scripts/release.sh` (executable), `scripts/ExportOptions.plist`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `MARKETING_VERSION` and `SUPublicEDKey` in `project.yml` (Tasks 2, 4); `scripts/check-vendored-notices.sh`.
- Produces: `dist/SpiceSee-<version>.dmg`, `dist/appcast.xml`. Flags: `--dry-run` (stop after the DMG, nothing submitted), `--beta` (appcast items tagged `beta`).

- [ ] **Step 1: Ignore the build outputs**

Append to `.gitignore`:

```
build/
dist/
```

- [ ] **Step 2: Write `scripts/ExportOptions.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>HBHQCPQ22A</string>
</dict>
</plist>
```

- [ ] **Step 3: Write `scripts/release.sh`**

```sh
#!/bin/sh
# Builds, signs, notarizes and stages a SpiceSee release in dist/ — the DMG and the Sparkle
# appcast — for manual upload to https://somecoolthings.com/spicesee.
# Design: docs/superpowers/specs/2026-09-02-spicesee-m7-ship-design.md §2.
#
#   scripts/release.sh             release build
#   scripts/release.sh --beta      same, appcast items on the "beta" channel
#   scripts/release.sh --dry-run   stop after the DMG: nothing is submitted to Apple
#
# Once, before the first run:  xcrun notarytool store-credentials notary --apple-id <id> --team-id HBHQCPQ22A
set -eu
cd "$(dirname "$0")/.."

TEAM=HBHQCPQ22A
PROFILE=notary
IDENTITY="Developer ID Application"
DOWNLOAD_PREFIX=https://somecoolthings.com/spicesee/

DRY_RUN=0
CHANNEL=""
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=1 ;;
    --beta) CHANNEL=beta ;;
    *) echo "usage: $0 [--dry-run] [--beta]" >&2; exit 2 ;;
  esac
done

fail() { echo "release: $*" >&2; exit 1; }

# --- preconditions -------------------------------------------------------------------------
[ -z "$(git status --porcelain)" ] || fail "working tree is dirty"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "release from main only"
BUILD=$(git rev-list --count HEAD)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
[ -n "$VERSION" ] || fail "MARKETING_VERSION not found in project.yml"
grep -qE 'SUPublicEDKey: "[A-Za-z0-9+/=]{40,}"' project.yml || fail "SUPublicEDKey in project.yml is not a real key"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || fail "no '$IDENTITY' identity in the keychain"
if [ $DRY_RUN = 0 ]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "no '$PROFILE' keychain profile — see the header"
fi
scripts/check-vendored-notices.sh || fail "vendored notices check failed"

echo "release: SpiceSee $VERSION (build $BUILD)${CHANNEL:+ [$CHANNEL]}"
rm -rf build dist
mkdir -p build dist

# --- archive and export ---------------------------------------------------------------------
xcodegen generate >/dev/null
ARCHIVE=build/SpiceSee.xcarchive
xcodebuild archive -quiet \
  -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  CURRENT_PROJECT_VERSION="$BUILD"
xcodebuild -exportArchive -quiet \
  -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export
APP=build/export/SpiceSee.app
[ -d "$APP" ] || fail "export produced no app"

# --- checks on the app ----------------------------------------------------------------------
codesign -vvv --deep --strict "$APP" 2>&1 | grep -q "satisfies its Designated Requirement" || fail "codesign --strict failed"
otool -L "$APP/Contents/MacOS/SpiceSee" | grep -q '@rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec' \
  || fail "CSpiceCodec is not linked as the embedded framework"
[ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)" = "$VERSION" ] || fail "app version mismatch"
[ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleVersion)" = "$BUILD" ] || fail "app build mismatch"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q disable-library-validation || fail "library-validation entitlement missing"

# --- DMG ------------------------------------------------------------------------------------
DMG="dist/SpiceSee-$VERSION.dmg"
make_dmg() {
  rm -rf build/dmg
  mkdir -p build/dmg
  cp -R "$APP" build/dmg/
  ln -s /Applications build/dmg/Applications
  hdiutil create -quiet -volname "SpiceSee $VERSION" -srcfolder build/dmg -ov -format UDZO "$DMG"
  codesign --timestamp -s "$IDENTITY" "$DMG"
}

notarize() {
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
  echo "$out"
  echo "$out" | grep -q "status: Accepted" \
    || fail "notarization of $1 was not accepted — xcrun notarytool log <id> --keychain-profile $PROFILE"
}

if [ $DRY_RUN = 1 ]; then
  make_dmg
  echo "release: dry run — $DMG built and signed, nothing notarized, no appcast"
  exit 0
fi

# The app is notarized and stapled on its own first, so a copy dragged out of the DMG validates
# offline; then the DMG, so Gatekeeper accepts the download itself.
ditto -c -k --keepParent "$APP" build/SpiceSee.zip
notarize build/SpiceSee.zip
xcrun stapler staple "$APP"
make_dmg
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | grep -q accepted || fail "spctl rejected the DMG"

# --- appcast --------------------------------------------------------------------------------
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)
[ -n "$SPARKLE_BIN" ] || fail "Sparkle tools not found under DerivedData — build the app once in Xcode/xcodebuild"
# Signs the DMG with the keychain's EdDSA key and writes dist/appcast.xml; release notes are
# picked up from dist/SpiceSee-$VERSION.html when present.
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" ${CHANNEL:+--channel "$CHANNEL"} dist

echo "release: staged in dist/ —"
ls -l dist
echo "release: upload the contents of dist/ to $DOWNLOAD_PREFIX"
```

```bash
chmod +x scripts/release.sh
```

- [ ] **Step 4: Dry run on this Mac**

The Developer ID identity is in the keychain, so archive, export, the checks and the DMG all run here without Apple:

```bash
scripts/release.sh --dry-run 2>&1 | tail -20
```

Expected: ends with `release: dry run — dist/SpiceSee-1.0.0.dmg built and signed …`. Then inspect:

```bash
codesign -dvv dist/SpiceSee-1.0.0.dmg 2>&1 | grep -E "Authority|TeamIdentifier"
hdiutil attach -quiet -nobrowse -mountpoint build/mnt dist/SpiceSee-1.0.0.dmg
codesign -dvv build/mnt/SpiceSee.app 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Timestamp"
codesign -dvv build/mnt/SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework 2>&1 | grep Authority | head -1
codesign -dvv build/mnt/SpiceSee.app/Contents/Frameworks/Sparkle.framework 2>&1 | grep Authority | head -1
ls build/mnt
hdiutil detach -quiet build/mnt
```

Expected: every `Authority` line begins `Developer ID Application: AARON JOHN POLLOCK (HBHQCPQ22A)`, the app shows a `Timestamp=`, and the volume lists `Applications` and `SpiceSee.app`. If `codesign --strict` fails on the app, print the full output (`codesign -vvv --deep --strict build/export/SpiceSee.app`) — the usual cause is a nested Sparkle XPC service left ad hoc, which means the export step did not run with `signingStyle: manual` and `signingCertificate`.

Also confirm the dirty-tree guard works: `touch x; scripts/release.sh --dry-run; rm x` → `release: working tree is dirty`, exit 1.

- [ ] **Step 5: Commit**

```bash
git add .gitignore scripts/release.sh scripts/ExportOptions.plist
git commit -m "build: scripts/release.sh — Developer ID archive, notarized DMG, Sparkle appcast

Signing identity, team and the commit-count build number are passed on the
archive command line; project.yml stays ad hoc for development. The app is
notarized and stapled before the DMG so a copied-out app validates offline.
--dry-run stops after the signed DMG; --beta tags appcast items.

Claude-Session: https://claude.ai/code/session_013BE2VqTBYVubDjeDPiuUAC"
```

---

### Task 6: `docs/replacing-the-codec.md` — the LGPL-2.1 §6(b) record

**Files:**
- Create: `docs/replacing-the-codec.md`
- Modify: `Sources/SpiceSee/AcknowledgementsView.swift` (callout text)

**Interfaces:**
- Consumes: `acknowledgementsSourceURL` from Task 1 (the callout's "Get the source…" button already opens it; this task only names the document in the callout copy).

- [ ] **Step 1: Verify the facts the document states**

```bash
otool -D build/export/SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework/Versions/A/CSpiceCodec 2>/dev/null \
  || otool -D "$(find ~/Library/Developer/Xcode/DerivedData -path '*/Debug/SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework/Versions/A/CSpiceCodec' | head -1)"
defaults read "$(find ~/Library/Developer/Xcode/DerivedData -path '*/Debug/SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework/Versions/A/Resources/Info' | head -1)" CFBundleIdentifier
nm -gU "$(find ~/Library/Developer/Xcode/DerivedData -path '*/Debug/SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework/Versions/A/CSpiceCodec' | head -1)" | grep -c " T _sc_"
```

Expected: install name `@rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec`; a bundle id (record whatever it prints — the backlog expects `cspicecodec.CSpiceCodec`); 17 exported `_sc_*` symbols. Put the actual values in the document.

- [ ] **Step 2: Write the document**

Create `docs/replacing-the-codec.md`:

```markdown
# Replacing the SPICE image codecs

SpiceSee's QUIC, LZ and GLZ decoders come from spice-common / spice-gtk and are licensed under
the GNU Lesser General Public License, version 2.1 or later. In line with LGPL-2.1 §6(b) they
ship as a separate dynamic framework you can replace with your own build. This page is the
information you need to do that. The framework's source, including the vendored files and the
record of what was changed (`Packages/CSpiceCodec/Sources/CSpiceCodec/VENDORED.md`), is at
https://github.com/aaronpollock/SpiceSee.

## What the app links

| | |
|---|---|
| Location in the bundle | `SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework` |
| Install name | `@rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec` |
| Bundle identifier | `<value from Step 1>` |
| Architecture / OS | arm64, macOS 14.0 or later |
| Interface | the `sc_*` functions declared in `Packages/CSpiceCodec/Sources/CSpiceCodec/include/spice_codec.h` |

The app is signed with the hardened runtime and the
`com.apple.security.cs.disable-library-validation` entitlement, so it loads a framework that is
not signed by SpiceSee's developer — an ad hoc signature is enough.

## The interface

`spice_codec.h` is the whole ABI. The app calls, and your build must export with C linkage:

- QUIC: `sc_quic_create`, `sc_quic_destroy`, `sc_quic_begin`, `sc_quic_decode`, `sc_quic_encode_rgb32`
- LZ: `sc_lz_create`, `sc_lz_destroy`, `sc_lz_begin`, `sc_lz_decode`, `sc_lz_encode_rgb32`, `sc_lz_encode_xxxa`
- GLZ: `sc_glz_window_create`, `sc_glz_window_clear`, `sc_glz_window_destroy`, `sc_glz_create`, `sc_glz_destroy`, `sc_glz_decode`

with the `sc_image_type` enumeration and the semantics documented in the header (in particular:
every entry point returns non-zero on a corrupt stream instead of aborting, and `sc_glz_decode`'s
output buffer is owned by the window until the next decode). The framework as shipped also exports
its internal symbols (`_quic_decode`, `_spice_malloc`, …); the app uses none of them.

## Building a replacement

This one-line build was verified against the app's replay golden test on 2026-08-26:

```sh
cd Packages/CSpiceCodec/Sources/CSpiceCodec
clang -dynamiclib -arch arm64 -mmacosx-version-min=14.0 -O2 \
  -Ivendor -Ivendor/common -Ishim -Iinclude \
  codec_bridge.c vendor/common/quic.c vendor/common/lz.c vendor/common/mem.c vendor/decode-glz.c \
  -install_name @rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec -o CSpiceCodec
```

## Installing it

1. Quit SpiceSee.
2. Copy your binary over
   `SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework/Versions/A/CSpiceCodec`.
3. Re-sign the framework ad hoc:
   `codesign -f -s - SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework`
4. Launch SpiceSee. Acknowledgements → "spice-common codecs" → *Show in Finder* opens the
   framework you just replaced.

Replacing the framework does not touch the app's own signature; Gatekeeper's first-launch check
of the downloaded app has already run. If you copy the modified app to another Mac, that Mac will
ask for confirmation once, as it does for any app whose contents changed after notarization.
```

Replace `<value from Step 1>` with the identifier printed in Step 1.

- [ ] **Step 3: Name the document in the callout**

In `Sources/SpiceSee/AcknowledgementsView.swift`, `frameworkCallout`, change the trailing sentence of the callout text from

```swift
                    + Text(" inside the app bundle, and library validation is disabled so you can substitute your own build. Source and the written offer are linked below.")
```

to

```swift
                    + Text(" inside the app bundle, and library validation is disabled so you can substitute your own build. The source link below includes docs/replacing-the-codec.md, which describes the interface and the build.")
```

- [ ] **Step 4: Build and test**

```bash
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "^(✘|✔ Test run)|error:"
```

- [ ] **Step 5: Commit**

```bash
git add docs/replacing-the-codec.md Sources/SpiceSee/AcknowledgementsView.swift
git commit -m "docs: replacing-the-codec.md — the LGPL-2.1 §6(b) record, named from the callout

Claude-Session: https://claude.ai/code/session_013BE2VqTBYVubDjeDPiuUAC"
```

---

### Task 7: Close the backlog — spec correction, exit checklist, CLAUDE.md, stale branch

**Files:**
- Modify: `docs/superpowers/specs/2026-08-22-spicesee-design.md` (lines 23-24, §8, M7 row)
- Append: `docs/dev-server.md`
- Delete: `docs/release-todo.md`
- Modify: `CLAUDE.md` (status paragraph, build commands)

- [ ] **Step 1: Correct the main design spec**

In `docs/superpowers/specs/2026-08-22-spicesee-design.md`:

Line 23-24, replace

```
**Deployment:** universal binary (arm64 + x86_64), macOS 14+, Developer ID + notarized DMG,
Sparkle 2 updates, Homebrew cask. Closed-source-capable.
```

with

```
**Deployment:** arm64, macOS 14+, Developer ID + notarized DMG at https://somecoolthings.com/spicesee,
Sparkle 2 updates. No Homebrew cask (decided 2026-08-28: it asks nothing of the build and would only
be a second front door to the same file). Closed-source-capable.
```

Replace the body of `## 8. Build and release` with:

```
SPM for libraries; Xcode project (generated from `project.yml` by xcodegen) for the bundle,
entitlements, and embedding `CSpiceCodec.framework`. Swift 6 strict concurrency. arm64, macOS 14+.
Developer ID, hardened runtime, library-validation entitlement, `notarytool`, stapled DMG,
Sparkle 2 (MIT). Release builds come from `scripts/release.sh` on the developer's Mac and are
uploaded by hand; no CI, no cask. Details and the decisions behind them:
`2026-09-02-spicesee-m7-ship-design.md`.
```

In the milestone table, replace the M7 row with:

```
| M7 | Ship | Connection manager, prefs, signed/notarized DMG, Sparkle — `scripts/release.sh` stages both |
```

- [ ] **Step 2: Append the M7 exit checklist to `docs/dev-server.md`**

```markdown

## M7 exit check (manual)

Machine-driveable half (this Mac, after the plan's Task 5):

- [ ] `scripts/release.sh --dry-run` exits 0 and `dist/SpiceSee-1.0.0.dmg` passes the codesign
      inspection in the plan's Task 5 Step 4.

The user's half:

- [ ] `xcrun notarytool store-credentials notary --apple-id aaron.pollock@outlook.com --team-id HBHQCPQ22A`
      (once; needs an app-specific password from appleid.apple.com).
- [ ] `scripts/release.sh` completes. **Record here whether Apple accepted the
      `disable-library-validation` entitlement** — the backlog's open question. Expected: accepted;
      if the submission comes back `Invalid`, `xcrun notarytool log <id> --keychain-profile notary`
      says why.
- [ ] Upload the contents of `dist/` to https://somecoolthings.com/spicesee/ so that
      `https://somecoolthings.com/spicesee/appcast.xml` and the DMG resolve.
- [ ] On a Mac other than the build machine: download the DMG from the site, drag SpiceSee to
      Applications, open it — no Gatekeeper prompt beyond the standard "downloaded from the
      internet" confirmation — and connect to the dev guest.
- [ ] Set `MARKETING_VERSION` to `1.0.1` in `project.yml`, commit, run `scripts/release.sh` again,
      upload. On the installed 1.0.0, Settings → Updates → Check Now offers 1.0.1, installs it, and
      relaunches.

Ticking the last two ships M7.
```

- [ ] **Step 3: Delete the backlog and update CLAUDE.md**

```bash
git rm -q docs/release-todo.md
```

In `CLAUDE.md`:

1. In the build-commands block after `swift Tools/make-icons.swift`, add:
   ```bash
   # a release: Developer ID archive, notarized + stapled DMG, Sparkle appcast, staged in dist/
   scripts/release.sh            # --dry-run stops after the signed DMG; --beta tags the appcast items
   ```
2. In the long status paragraph under `## Architecture`, replace `M7 (ship) is next.` with:
   `**M7 (ship) is built** — Sparkle 2 wired to the Updates pane, `scripts/release.sh` producing the notarized DMG and appcast — and ships when the manual exit check in `docs/dev-server.md` (`## M7 exit check (manual)`) is ticked.`
3. In the `## Licensing constraint` section, after "with Sparkle for updates (M7).", add: `The §6(b) record is `docs/replacing-the-codec.md`.`
4. Add to `## Conventions`: `The build number is `CURRENT_PROJECT_VERSION`, passed by `scripts/release.sh` as the git commit count; a development build is build 0 and `MARKETING_VERSION` in `project.yml` is the only version to bump by hand.`

- [ ] **Step 4: Delete the stale branch and verify docs render**

```bash
git branch -d codec-dynamic-framework
grep -c "release-todo" CLAUDE.md docs/dev-server.md docs/superpowers/specs/*.md || true
```

Expected: the branch deletes cleanly (it was merged in `f70472b`); no remaining references to `release-todo.md` outside the M7 spec's own sentence about deleting it.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/dev-server.md docs/superpowers/specs/2026-08-22-spicesee-design.md
git commit -m "docs: close the release backlog — spec §8 corrected, M7 exit check, CLAUDE.md status

Claude-Session: https://claude.ai/code/session_013BE2VqTBYVubDjeDPiuUAC"
```

---

### Task 8: Ship (the user's)

No code. Work through `## M7 exit check (manual)` in `docs/dev-server.md`. When the last two boxes are ticked, tick the M7 row's status in `CLAUDE.md` ("is built" → "shipped on <date>") and commit that with `docs:`. Then, per `CLAUDE.md`, delete any DerivedData directories other than the main checkout's and refresh `~/Applications/SpiceSee.app` from the Release build in `build/export/` if that copy exists.
