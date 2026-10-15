#!/bin/zsh
# Builds the download: a signed and notarized build/Zweiklang.dmg.
# Usage: scripts/release.sh             build, notarize and check the DMG
#        scripts/release.sh --publish   additionally create the GitHub release v<version> with the DMG
#
# One-time setup on the release Mac:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > "Developer ID Application".
#   2. Store notarization credentials in the keychain, either with an App Store Connect API key
#        xcrun notarytool store-credentials zweiklang-notary --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer-id>
#      or with an app-specific password
#        xcrun notarytool store-credentials zweiklang-notary --apple-id <apple-id> --team-id <team-id>
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE=${NOTARY_PROFILE:-zweiklang-notary}
# The installer instructions in AGENTS.md check for exactly this team.
TEAM=${ZWEIKLANG_TEAM:-G2R8R847MM}

LINE=$(security find-identity -v -p codesigning | grep "\"Developer ID Application: .*($TEAM)\"" | head -1 || true)
if [[ -z "$LINE" ]]; then
  echo "No “Developer ID Application” certificate for team $TEAM in the keychain (see setup at the top of this script)." >&2
  exit 1
fi
IDENTITY=$(print -r -- "$LINE" | awk '{print $2}')
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "Notarization profile “$PROFILE” is missing (see setup at the top of this script)." >&2
  exit 1
fi

# Submits a file to Apple and waits; fails unless Apple accepts it. Stapling is separate (a ZIP cannot be stapled).
notarize() {
  local file="$1" result
  result=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json)
  if [[ "$(print -r -- "$result" | plutil -extract status raw -o - -)" != "Accepted" ]]; then
    print -r -- "$result" >&2
    echo "Notarization failed. Details: xcrun notarytool log <id> --keychain-profile $PROFILE" >&2
    exit 1
  fi
}

# 1. Build (universal: Apple silicon and Intel), test, sign with Developer ID.
xcodegen generate --quiet
xcodebuild -project Zweiklang.xcodeproj -scheme Zweiklang -derivedDataPath build/DerivedData test -quiet
xcodebuild -project Zweiklang.xcodeproj -scheme Zweiklang -configuration Release -derivedDataPath build/DerivedData clean build -quiet
APP=build/DerivedData/Build/Products/Release/Zweiklang.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
scripts/sign.sh "$APP" "$IDENTITY"
if ! codesign -dv "$APP" 2>&1 | grep -q "^TeamIdentifier=$TEAM\$"; then
  echo "The app is not signed by team $TEAM." >&2
  exit 1
fi

# 2. Notarize and staple the app itself, so it also opens offline after copying it out of the DMG.
rm -rf build/release
mkdir -p build/release/dmg
ditto -c -k --keepParent "$APP" build/release/Zweiklang.zip
notarize build/release/Zweiklang.zip
xcrun stapler staple "$APP"

# 3. DMG with the usual drag-to-Applications window, signed and notarized as well.
ditto "$APP" build/release/dmg/Zweiklang.app
ln -s /Applications build/release/dmg/Applications
hdiutil create -volname "Zweiklang" -srcfolder build/release/dmg -fs HFS+ -format UDZO -ov build/Zweiklang.dmg -quiet
codesign --force --sign "$IDENTITY" --timestamp build/Zweiklang.dmg
notarize build/Zweiklang.dmg
xcrun stapler staple build/Zweiklang.dmg

# 4. Check it the way Gatekeeper will on a friend's Mac.
spctl --assess --type open --context context:primary-signature -v build/Zweiklang.dmg
spctl --assess --type execute -v "$APP"
echo "Ready: build/Zweiklang.dmg (Zweiklang $VERSION, team $TEAM)"

if [[ "${1:-}" == "--publish" ]]; then
  gh release create "v$VERSION" build/Zweiklang.dmg --title "Zweiklang $VERSION" --generate-notes
fi
