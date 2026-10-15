#!/bin/zsh
# Builds the download: a signed and notarized build/Zweiklang.dmg.
# Usage: scripts/release.sh                        build, notarize and check the DMG, write the appcast
#        scripts/release.sh --publish [notes.md]   additionally create the GitHub release v<version>
#                                                  with Zweiklang.dmg and appcast.xml
#
# One-time setup on the release Mac:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > "Developer ID Application".
#   2. Store notarization credentials in the keychain, either with an App Store Connect API key
#        xcrun notarytool store-credentials zweiklang-notary --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer-id>
#      or with an app-specific password
#        xcrun notarytool store-credentials zweiklang-notary --apple-id <apple-id> --team-id <team-id>
#   3. Sparkle update key (EdDSA) in the keychain, account "zweiklang"; its public half is SPARKLE_PUBLIC_KEY
#      in project.yml. Created once with
#        build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account zweiklang
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
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
if [[ -z "$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null)" ]]; then
  echo "SUPublicEDKey is empty: installed apps could not verify updates." >&2
  exit 1
fi
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

# 4. Appcast: tells installed copies about this version. Sparkle checks the EdDSA signature and,
#    because the app is signed, also that the update comes from the same Developer ID.
SPARKLE_BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account zweiklang build/Zweiklang.dmg)
cat > build/appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Zweiklang</title>
    <item>
      <title>Zweiklang $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/Mooned8/zweiklang/releases/tag/v$VERSION</link>
      <enclosure url="https://github.com/Mooned8/zweiklang/releases/download/v$VERSION/Zweiklang.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST
xmllint --noout build/appcast.xml

# 5. Check it the way Gatekeeper will on a friend's Mac.
spctl --assess --type open --context context:primary-signature -v build/Zweiklang.dmg
spctl --assess --type execute -v "$APP"
echo "Ready: build/Zweiklang.dmg (Zweiklang $VERSION, team $TEAM)"

if [[ "${1:-}" == "--publish" ]]; then
  NOTES=(--generate-notes)
  [[ -n "${2:-}" ]] && NOTES=(--notes-file "$2")
  gh release create "v$VERSION" build/Zweiklang.dmg build/appcast.xml --repo Mooned8/zweiklang \
    --target "$(git rev-parse HEAD)" --title "Zweiklang $VERSION" "${NOTES[@]}"
fi
