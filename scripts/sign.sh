#!/bin/zsh
# Signs Zweiklang.app inside out (framework first, then the app).
# Usage: scripts/sign.sh <path/to/Zweiklang.app> <identity>
#   identity: SHA-1 of a "Developer ID Application" or "Apple Development" certificate, or "-" for ad hoc.
# With a real certificate the app gets the hardened runtime and a secure timestamp, and macOS keeps
# its privacy permissions (Accessibility for the volume keys) across updates.
set -euo pipefail
APP="$1"
IDENTITY="$2"

FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  # Hardened runtime needs a team signature on every loaded library, so ad hoc builds go without it.
  FLAGS+=(--options runtime --timestamp)
fi

for framework in "$APP"/Contents/Frameworks/*.framework(N); do
  codesign "${FLAGS[@]}" "$framework"
done
codesign "${FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
