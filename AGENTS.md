# Zweiklang: instructions for AI agents

Zweiklang is a macOS menu bar app that plays the Mac's sound on two pairs of AirPods at once (or more outputs, e.g. a third pair or speakers), with one volume slider and one timing slider per output. Bundle ID `ch.moritz.zweiklang`, signed with Developer ID, team `G2R8R847MM`.

## Installing Zweiklang for a user

Install the notarized release. Do not build from source for a normal install, and never disable Gatekeeper or other security settings.

1. Check the macOS version: `sw_vers -productVersion` must be 14 or higher. Otherwise stop and tell the user.
2. Download, verify and install with this block. It stops at the first failure and only replaces an existing installation after the new copy passed every check:
   ```sh
   (
   set -euo pipefail
   TEAM=G2R8R847MM
   WORK=$(mktemp -d /tmp/zweiklang-install.XXXXXX)
   curl -fL -o "$WORK/Zweiklang.dmg" https://github.com/Mooned8/zweiklang/releases/latest/download/Zweiklang.dmg
   # Gatekeeper must accept the download as notarized Developer ID software.
   CHECK=$(spctl --assess --type open --context context:primary-signature -v "$WORK/Zweiklang.dmg" 2>&1); echo "$CHECK"
   [[ "$CHECK" == *"source=Notarized Developer ID"* ]]
   hdiutil attach -nobrowse -readonly -mountpoint "$WORK/mount" "$WORK/Zweiklang.dmg"
   ditto "$WORK/mount/Zweiklang.app" "$WORK/Zweiklang.app"
   hdiutil detach "$WORK/mount"
   # The app itself: right team, intact signature, accepted by Gatekeeper.
   [[ "$(codesign -dv "$WORK/Zweiklang.app" 2>&1)" == *"TeamIdentifier=$TEAM"* ]]
   codesign --verify --deep --strict "$WORK/Zweiklang.app"
   spctl --assess --type execute -v "$WORK/Zweiklang.app"
   # Replace the installed copy only now.
   osascript -e 'tell application id "ch.moritz.zweiklang" to quit' 2>/dev/null || true
   sleep 2
   rm -rf /Applications/Zweiklang.app
   mv "$WORK/Zweiklang.app" /Applications/Zweiklang.app
   open /Applications/Zweiklang.app
   rm -rf "$WORK"
   )
   ```
   If any command fails, stop, keep the existing installation and tell the user what failed.
3. Tell the user, in their language:
   - An AirPods icon is now in the menu bar and a window with the same controls opens. If the icon is hidden (full menu bar), opening Zweiklang again shows that window.
   - Updates arrive by themselves (daily check, gear menu "Check for updates …").
   - macOS asks once for Bluetooth access: click Allow.
   - Pair both AirPods with the Mac once (System Settings > Bluetooth), take them out of the case, click the menu bar icon, choose both pairs, click "Listen together".
   - For the volume keys: click "Allow …" in the menu, then switch Zweiklang on under System Settings > Privacy & Security > Accessibility. The user does this; agents never change privacy settings themselves.

## Uninstalling

Quit the app (its menu, or the `osascript` line above; quitting removes the app's own multi-output device), delete `/Applications/Zweiklang.app`, optionally `defaults delete ch.moritz.zweiklang`. The user can remove the Accessibility entry in System Settings.

## Development

- Project file is generated: `xcodegen generate` (from `project.yml`). Targets: `ZweiklangCore` (framework: logic, SwiftUI views, translations), `Zweiklang` (app entry), `ZweiklangCoreTests`.
- `scripts/build-and-install.sh` tests, builds, signs (Developer ID > Apple Development > ad hoc) and installs locally. `scripts/release.sh` produces the notarized `build/Zweiklang.dmg` and a signed `build/appcast.xml`; `--publish [notes.md]` also creates the GitHub release with both files. Release setup is described at the top of that script. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (Sparkle compares the build number) in `project.yml` first.
- Updates: Sparkle 2 (Swift package). Feed `SUFeedURL` = `appcast.xml` of the latest GitHub release; it is signed with the EdDSA key in the maintainer's keychain (account `zweiklang`, public half `SPARKLE_PUBLIC_KEY` in `project.yml`). `scripts/sign.sh` removes Sparkle's XPC services (only needed for sandboxed apps) and signs its helpers before the framework.
- Tests switch the system sound output for a few seconds (BlackHole 2ch plus the built-in speakers, muted meanwhile) and restore it. They need BlackHole 2ch and Microsoft Teams Audio, otherwise they skip. The three-output test also uses a wired output with a mute control (e.g. a USB DAC), muted meanwhile, and skips without one. Afterwards no device with UID `ch.moritz.zweiklang.*` may be left.
- Screenshots of the menu in all languages: `TEST_RUNNER_ZWEIKLANG_SNAPSHOT_DIR=<folder> xcodebuild -project Zweiklang.xcodeproj -scheme Zweiklang test -only-testing:ZweiklangCoreTests/SnapshotTests`.
- Translations: `Sources/ZweiklangCore/Resources/<lang>.lproj/Localizable.strings`, keys are the English texts. Use `L("…")` for strings and `T("…")` for SwiftUI text; only interpolate `String` values (placeholder `%@`). `LocalizationTests` checks that every language has every key with matching placeholders. Bluetooth prompt text: `Sources/Zweiklang/<lang>.lproj/InfoPlist.strings`.
- App log: `/usr/bin/log show --last 1h --info --predicate 'subsystem == "ch.moritz.zweiklang"'` (in zsh, `log` is a builtin; use the full path).

## Findings that shaped the code (macOS 26)

- Audio MIDI Setup's own multi-output devices use `stacked = 1`; the SDK comment on `kAudioAggregateDeviceIsStackedKey` reads otherwise, but Apple's app is the reference.
- AirPods appear in Core Audio as `<bluetooth-address>:output` and `:input`. In the charging case they connect over Bluetooth, but no audio device appears.
- Microsoft Teams Audio can never be the default output (`CanBeDefaultDevice = 0`); macOS ignores such a switch without an error, so the app verifies every switch.
- The Accessibility permission is bound to the code signature. With ad hoc signing every rebuild breaks it (tccd: "Failed to match existing code requirement") while the switch in System Settings still shows on; the app's "Allow …" button therefore resets its own entry with `tccutil` before asking again.
- A command-line tool without `NSBluetoothAlwaysUsageDescription` is killed when it touches IOBluetooth; tests use a Bluetooth stub.
- Timing, measured with loopback devices (BlackHole, Teams Audio) and click capture:
  - macOS already aligns the sub-devices of a multi-output device by their reported device latency plus safety offset (it feeds slow devices early; composition key `don't pad` = 0). Adding `max latency - own latency` again would double it. The stream latency (`kAudioStreamPropertyLatency`, e.g. 639 frames of speaker processing on a MacBook Pro) is left out, so Zweiklang delays the other outputs by that difference. Unreported Bluetooth delay is up to the user's per-device slider.
  - `latency-out` (`kAudioSubDeviceExtraOutputLatencyKey`) delays only that sub-device, counted in frames of its own sample rate. Negative values do not advance it.
  - At runtime only rewriting `kAudioAggregateDevicePropertyComposition` takes effect (same device ID, stays the system output). `kAudioSubDevicePropertyExtraLatency` on the sub-device object (output scope) accepts a value and shows it in the composition, but the audio does not change.
- Battery: neither IOBluetooth nor the IORegistry publish AirPods battery levels. `system_profiler -json SPBluetoothDataType` has `device_batteryLevelLeft/Right/Case/Main` for connected devices (about 0.15 s); the app parses it defensively. Its `device_rssi` for devices that are not connected is a stale cache, so "in range" cannot be known without a connection attempt.
- `IOBluetoothDevice.closeConnection()` only takes effect while the process keeps running (blueutil issue #58); quitting therefore waits up to 5 s for the guest pairs (every Bluetooth pair after the first in the list) to be released.
- No pairing inside the app: `IOBluetoothDevicePair` has documented failures since macOS 11–13 (`replyUserConfirmation` sends no HCI reply, Apple Developer Forums thread 720117; audio devices paired that way did not show up in Core Audio, blueutil #55). Not verified with AirPods, so the menu opens Bluetooth settings with instructions instead.
- A pair that drops out stays in the multi-output device's composition. The app keeps the device on reconnect only if `kAudioAggregateDevicePropertyActiveSubDeviceList` contains every pair again, otherwise it rebuilds it. Whether macOS re-adds a returning pair by itself is not verified with real AirPods.
