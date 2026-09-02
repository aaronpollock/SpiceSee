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
if [ $DRY_RUN = 0 ]; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "release from main only"
fi
BUILD=$(git rev-list --count HEAD)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
[ -n "$VERSION" ] || fail "MARKETING_VERSION not found in project.yml"
DMG="dist/SpiceSee-$VERSION.dmg"
grep -qE 'SUPublicEDKey: "[A-Za-z0-9+/=]{40,}"' project.yml || fail "SUPublicEDKey in project.yml is not a real key"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || fail "no '$IDENTITY' identity in the keychain"
if [ $DRY_RUN = 0 ]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "no '$PROFILE' keychain profile — see the header"
fi
scripts/check-vendored-notices.sh || fail "vendored notices check failed"

echo "release: SpiceSee $VERSION (build $BUILD)${CHANNEL:+ [$CHANNEL]}"
rm -rf build
mkdir -p build dist
rm -f "$DMG"

# --- archive and export ---------------------------------------------------------------------
xcodegen generate >/dev/null
ARCHIVE=build/SpiceSee.xcarchive
xcodebuild archive -quiet \
  -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  CURRENT_PROJECT_VERSION="$BUILD" ARCHS=arm64
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
make_dmg() {
  rm -rf build/dmg
  mkdir -p build/dmg
  cp -R "$APP" build/dmg/
  ln -s /Applications build/dmg/Applications
  hdiutil create -quiet -volname "SpiceSee $VERSION" -srcfolder build/dmg -ov -format UDZO "$DMG"
  codesign --timestamp -s "$IDENTITY" "$DMG"
}

notarize() {
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m 2>&1) || true
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
# picked up from dist/SpiceSee-$VERSION.html when present. dist/ is kept between releases so
# earlier DMGs stay in the appcast; deltas are out of scope.
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" --maximum-deltas 0 \
  ${CHANNEL:+--channel "$CHANNEL"} dist

echo "release: staged in dist/ —"
ls -l dist
echo "release: upload the contents of dist/ to $DOWNLOAD_PREFIX"
