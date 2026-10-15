#!/bin/zsh
# Developer install: tests, builds and installs Zweiklang to /Applications on this Mac.
# Usage: scripts/build-and-install.sh [--skip-tests]
# Needs Xcode and xcodegen (brew install xcodegen). Friends should use the release download instead.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
if [[ "${1:-}" != "--skip-tests" ]]; then
  xcodebuild -project Zweiklang.xcodeproj -scheme Zweiklang -derivedDataPath build/DerivedData test -quiet
fi
xcodebuild -project Zweiklang.xcodeproj -scheme Zweiklang -configuration Release -derivedDataPath build/DerivedData build -quiet
APP=build/DerivedData/Build/Products/Release/Zweiklang.app

# Signature: Developer ID (same identity as the downloads) > Apple Development > ad hoc.
# Only a real certificate lets macOS keep the Accessibility permission after a rebuild.
IDENTITIES=$(security find-identity -v -p codesigning)
IDENTITY=$(print -r -- "$IDENTITIES" | awk '/"Developer ID Application: /{print $2; exit}')
[[ -n "$IDENTITY" ]] || IDENTITY=$(print -r -- "$IDENTITIES" | awk '/"Apple Development: /{print $2; exit}')
[[ -n "$IDENTITY" ]] || IDENTITY="-"
scripts/sign.sh "$APP" "$IDENTITY"

# Normal quit, so a running session ends cleanly; pkill only as fallback.
if pgrep -x Zweiklang >/dev/null; then
  osascript -e 'tell application id "ch.moritz.zweiklang" to quit' 2>/dev/null || true
  for _ in {1..20}; do pgrep -x Zweiklang >/dev/null || break; sleep 0.25; done
  pkill -x Zweiklang 2>/dev/null || true
fi
# Replace instead of merge, so files dropped from a newer build do not linger.
rm -rf "/Applications/Zweiklang.app"
ditto "$APP" "/Applications/Zweiklang.app"
open /Applications/Zweiklang.app

if [[ "$IDENTITY" == "-" ]]; then
  echo "Installed /Applications/Zweiklang.app (ad hoc signature: click “Allow …” in the menu once for the volume keys)."
else
  echo "Installed /Applications/Zweiklang.app (signed with a certificate)."
fi
