# SpiceSee M7 — Ship: notarized DMG, Sparkle updates, LGPL §6(b) record

Design for milestone M7 of `2026-08-22-spicesee-design.md` ("Ship"). The connection manager and
preferences the M7 row lists are already built; what remains is distribution. Decisions taken on
2026-09-02, superseding §8 of the main spec where they differ: **arm64 only**, **notarized DMG at
https://somecoolthings.com/spicesee**, **Sparkle 2 in 1.0.0**, **no Homebrew cask**, **no CI** —
release builds come from `scripts/release.sh` on the developer's Mac, and the script *stages* the
release in `dist/`; uploading to the site is a manual step. `docs/release-todo.md` (2026-08-28) is
the backlog this spec closes; its verified facts still hold: Developer ID identity `HBHQCPQ22A`
is in the keychain, hardened runtime is on, the only entitlements are `network.client` and
`disable-library-validation`, and `CSpiceCodec.framework` is embedded and separately signed.

**Out of scope:** universal binary, Homebrew cask, GitHub Actions, the website itself, delta
updates, Sparkle's sandboxed XPC configuration (the app is not sandboxed), and any change to the
engine. The M4 real-traffic check stays vacuous for the reasons in `docs/dev-server.md` and is not
an M7 exit item.

## 1. Sparkle

**Dependency.** `project.yml` adds the `sparkle-project/Sparkle` package (pinned with `exactVersion: "2.9.6"`; bumped deliberately)
and the `SpiceSee` target depends on its `Sparkle` product. `SpiceSeeTests` compiles the app's
sources into itself, so it takes the same dependency. Xcode's archive/export re-signs Sparkle's
XPC services and helper with the app's identity; the Debug build leaves them ad hoc, which is
fine for development.

**Wiring.** One `SPUStandardUpdaterController` is owned by `SpiceSeeApp`, started at init, with an
updater delegate (`UpdaterDelegate`, a small `NSObject` in a new `Sources/SpiceSee/Updater.swift`)
whose only job is `allowedChannels(for:)`: `["beta"]` when "Include pre-release builds" is on,
empty otherwise. The three Updates-pane toggles change meaning, not layout:

| Pane control | Backed by |
|---|---|
| Check for updates automatically | `SPUUpdater.automaticallyChecksForUpdates` |
| Download and install in the background | `SPUUpdater.automaticallyDownloadsUpdates` (disabled while the first is off) |
| Include pre-release builds | `AppSettings.includePrereleases` (ours; read by the delegate) |
| Check Now | `SPUUpdater.checkForUpdates()` |
| version line | `SPUUpdater.lastUpdateCheckDate` replaces `AppSettings.lastUpdateCheck` |

Sparkle persists the first two in user defaults itself, so `AppSettings.checkForUpdatesAutomatically`
and `installInBackground` go away; the pane sets updater properties only on user change, per
Sparkle's guidance. A "Check for Updates…" item joins the app menu after About, disabled while
`canCheckForUpdates` is false. `Info.plist` gains `SUFeedURL`
(`https://somecoolthings.com/spicesee/appcast.xml`) and `SUPublicEDKey`; `SUEnableInstallerLauncherService`
is not needed outside the sandbox. The EdDSA key pair is generated once with Sparkle's
`generate_keys` — the private key lives in the developer's keychain and is never in the repo.

**Channel.** Pre-release builds are published with `<sparkle:channel>beta</sparkle:channel>`; the
release script tags them from a `--beta` flag. Sparkle compares `CFBundleVersion`, which is why
the version scheme below has to be monotonic.

## 2. Versioning and the release script

**Version.** `CFBundleShortVersionString` / `MARKETING_VERSION` become `1.0.0` in `project.yml`.
`CFBundleVersion` is no longer hand-maintained: the script passes
`CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)` on the archive command line, and
`project.yml` reads `CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"` with a base of `0` so a
development build is visibly not a release. The commit count is monotonic on `main`, which is all
Sparkle needs.

**`scripts/release.sh`** — one command, no arguments for a release, `--beta` for a pre-release.
It refuses a dirty tree or a branch other than `main`, then:

1. `xcodegen generate`
2. `xcodebuild archive` — scheme `SpiceSee`, Release, `generic/platform=macOS`,
   `DEVELOPMENT_TEAM=HBHQCPQ22A CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual
   CURRENT_PROJECT_VERSION=<count>`. `project.yml` keeps ad hoc signing for development; nothing
   about signing is committed.
3. `xcodebuild -exportArchive` with an `ExportOptions.plist` (`method: developer-id`,
   `signingStyle: manual`, `teamID`) — Xcode re-signs the nested codec framework and Sparkle's
   helpers and adds secure timestamps.
4. DMG: `hdiutil create` from a staging folder holding `SpiceSee.app` and an `Applications`
   symlink, UDZO, named `SpiceSee-<version>.dmg` (`create-dmg` is not installed and not needed).
5. `xcrun notarytool submit --keychain-profile notary --wait`; on success `xcrun stapler staple`
   the DMG. The app inside is also stapled before the DMG is built, so a copied-out app validates
   offline.
6. Checks, each fatal: `codesign -vvv --deep --strict` on the app; `spctl --assess --type open
   --context context:primary-signature` on the DMG; `otool -L` shows
   `@rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec`; `scripts/check-vendored-notices.sh`
   exits 0; the app's `Info.plist` carries the expected version and build.
7. `generate_appcast dist/` (from the Sparkle package's `bin/`), which signs the DMG with the
   keychain's EdDSA key and writes or updates `dist/appcast.xml`. Release notes come from
   `dist/SpiceSee-<version>.html` if present.

`dist/` is gitignored. The first submission answers the open question from the backlog —
whether Apple accepts `disable-library-validation` on this bundle — and the answer is recorded
under `## M7 exit check (manual)` in `docs/dev-server.md`. `docs/release-todo.md` is deleted once
this spec's plan has landed; this document and that section replace it.

## 3. Housekeeping the release makes necessary

- **Acknowledgements.** Remove the libopus entry: M6 decodes Opus through AudioToolbox, and
  libopus is used only by the fixture tool `Tools/opusref.c`, which does not ship. Sparkle's entry
  stays; `Licenses/MIT.txt` becomes Sparkle's actual licence text with its copyright line instead
  of the `<year> <copyright holders>` template. `acknowledgementsSourceURL` becomes
  `https://github.com/aaronpollock/SpiceSee` (the repo is public, so the written offer's link is
  live). The `placeholderLicenseText` guard and its `TODO(release)` go.
- **`docs/replacing-the-codec.md`** — the LGPL-2.1 §6(b) record, per the backlog: install name,
  location, bundle id, the `sc_*` API in `spice_codec.h`, arm64 / macOS 14+, the verified one-line
  `clang` build, the ad hoc `codesign -f -s -` step, and the note that the framework currently
  exports internal symbols too. The acknowledgements callout links to it via the repo URL.
- **`Info.plist`**: `LSApplicationCategoryType: public.app-category.utilities`.
- **Design spec §8 and the M7 row** are corrected in place to match the decisions above, with a
  one-line pointer to this document.
- The stale local `codec-dynamic-framework` branch is deleted (merged in `f70472b`).

## 4. Testing and exit criteria

**Automated (SpiceSeeTests).** `UpdaterDelegate.allowedChannels` returns `["beta"]` iff
pre-releases are on; the `AppSettings` defaults round-trip drops the two keys Sparkle now owns;
`AcknowledgementComponent.all` no longer contains libopus and every entry's licence file loads
from the bundle and is not the template. `swift test` and the app test bundle stay green.

**Script self-checks** are the verification for steps 2–7: the script exits non-zero if any
fails, and a dry run (`--dry-run`) stops after step 4 so the archive and DMG can be inspected
without a notarization round-trip.

**Manual, the user's (`docs/dev-server.md`, `## M7 exit check (manual)`):**

1. `xcrun notarytool store-credentials notary --apple-id … --team-id HBHQCPQ22A` (once).
2. `generate_keys` (once); paste the printed public key into `project.yml`.
3. `scripts/release.sh` completes; upload `dist/` to the site.
4. On a Mac other than the build machine: download the DMG from the site, drag to Applications,
   open — no Gatekeeper prompt — and connect to the dev guest.
5. Set `MARKETING_VERSION` to `1.0.1`, commit, run `scripts/release.sh` again (the commit count
   rises with it), upload; on the installed 1.0.0, Settings → Updates → Check Now offers 1.0.1,
   installs it, and relaunches.

Ticking 4 and 5 ships M7.
