# Release to-do

What stands between the `codec-dynamic-framework` branch and a notarized DMG at
https://somecoolthings.com/spicesee. Verified state as of 2026-08-28: Developer ID identity
`HBHQCPQ22A` is in the keychain, hardened runtime is on, the only entitlements are
`network.client` and `disable-library-validation`, and `CSpiceCodec.framework` is embedded and
separately signed.

## 1. Make the acknowledgements window true

`Sources/SpiceSee/AcknowledgementsView.swift` credits **libopus** ("linked as a static library")
and **Sparkle** ("used to check for, download, and install app updates"). Neither is in the
bundle — audio is M6, Sparkle is M7. Remove both entries (or gate them the way
`showsFrameworkCallout` gates the codec callout) until their milestones land. The Settings
**Updates** pane (`SettingsView.swift`, `UpdatesPane`) has a "Check for updates automatically"
toggle with nothing behind it — hide it until Sparkle ships, or wire it (see 5).

## 2. Notarization credentials (interactive, once)

```
xcrun notarytool store-credentials notary --apple-id aaron.pollock@outlook.com --team-id HBHQCPQ22A
```
Needs an app-specific password from appleid.apple.com. Nothing else in this list can be
finished without it.

## 3. Release script → notarized DMG

`project.yml` signs ad hoc (`CODE_SIGN_IDENTITY: "-"`, no `DEVELOPMENT_TEAM`); leave it so for
development and override on the archive command line. `scripts/release.sh`:

1. `xcodegen generate`
2. `xcodebuild archive -scheme SpiceSee -configuration Release -destination 'generic/platform=macOS' DEVELOPMENT_TEAM=HBHQCPQ22A`
3. `xcodebuild -exportArchive` with `method: developer-id` — Xcode re-signs the nested framework
   and adds secure timestamps
4. `hdiutil create` a DMG (`create-dmg` is not installed; `hdiutil` is enough)
5. `xcrun notarytool submit --keychain-profile notary --wait`, then `xcrun stapler staple`
6. Final checks: `codesign -vvv --strict`, `spctl --assess --type open --context context:primary-signature` on the DMG,
   `otool -L Contents/MacOS/SpiceSee | grep CSpiceCodec` shows the `@rpath` entry, and
   `scripts/check-vendored-notices.sh` exits 0

The first submission answers the open question: whether Apple accepts
`disable-library-validation` on this bundle. Expect yes; confirm.

Also: `LSApplicationCategoryType` is missing from `Info.plist`, and `CFBundleVersion` (`142`) is
hand-maintained — derive it from the git commit count in the script.

## 4. Document the replacement-framework ABI (LGPL-2.1 §6(b))

A short `docs/replacing-the-codec.md`, linked from the acknowledgements callout text:

- Install name: `@rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec`; location
  `Contents/Frameworks/CSpiceCodec.framework`; bundle id as Xcode emits it (`cspicecodec.CSpiceCodec`)
- API: the `sc_*` functions in `Packages/CSpiceCodec/Sources/CSpiceCodec/include/spice_codec.h`;
  arm64, macOS 14+
- One-line build that is known to work (verified 2026-08-26 against the ReplayTests golden):
  ```
  cd Packages/CSpiceCodec/Sources/CSpiceCodec
  clang -dynamiclib -arch arm64 -mmacosx-version-min=14.0 -O2 -Ivendor -Ivendor/common -Ishim -Iinclude \
    codec_bridge.c vendor/common/quic.c vendor/common/lz.c vendor/common/mem.c vendor/decode-glz.c \
    -install_name @rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec -o CSpiceCodec
  ```
- Drop in, then `codesign -f -s - CSpiceCodec.framework` — ad hoc is enough under the app's
  `disable-library-validation` entitlement
- Optional: an exported-symbols list so the framework's ABI is `sc_*` only; today it exports every
  internal symbol (`_quic_decode`, `_spice_malloc`, …)

## 5. Updates feed at somecoolthings.com/spicesee (M7)

The site is the Sparkle appcast host. When M7 lands: `SUFeedURL`
`https://somecoolthings.com/spicesee/appcast.xml`, `SUPublicEDKey` from `generate_keys`, the DMG
from 3 uploaded alongside, and `generate_appcast` run over the release directory. Until then the
Updates pane stays hidden (1). Sparkle is MIT — the acknowledgement entry and `MIT.txt` come back
with it.
