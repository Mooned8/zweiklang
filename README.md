# Zweiklang

**Two AirPods, one Mac, one film.** Zweiklang is a small menu bar app for macOS that plays your Mac's sound on two pairs of AirPods at the same time, each with its own volume slider. No more fiddling in Audio MIDI Setup.

<img src="docs/screenshot.png" width="300" alt="Zweiklang menu with one volume slider per pair of AirPods">

- Connects both pairs of AirPods with one click and switches the Mac's sound to both.
- One volume slider per pair, optionally linked.
- The keyboard volume keys change both pairs at once (with a small on-screen display, also over full-screen video).
- "Stop listening together" brings back the previous sound output.
- Speaks English, German, Spanish, French, Italian, Dutch and Portuguese, following the Mac's language.

## Install

1. Download **[Zweiklang.dmg](https://github.com/Mooned8/zweiklang/releases/latest/download/Zweiklang.dmg)** (latest release).
2. Open it and drag **Zweiklang** into **Applications**.
3. Open Zweiklang from Applications. An AirPods icon appears in the menu bar.

Requires macOS 14 Sonoma or later, on Apple silicon or Intel. The app is signed and notarized by Apple.

### Install with your AI agent

Tell your coding agent (Claude Code, Codex, …):

> Install the Mac app Zweiklang for me from https://github.com/Mooned8/zweiklang. Follow the instructions in its AGENTS.md.

## How to use

1. Pair both AirPods with the Mac once (System Settings > Bluetooth). Your friend's AirPods only need this the first time.
2. Take both pairs out of their cases.
3. Click the AirPods icon in the menu bar, pick the two pairs and click **Listen together**.
4. Adjust each pair with its slider. **Stop listening together** ends it.

On first launch macOS asks whether Zweiklang may use Bluetooth: click **Allow**.
For the volume keys, click **Allow …** in the menu once and switch Zweiklang on under System Settings > Privacy & Security > Accessibility. The gear icon turns this off if you do not want it.

Shortcuts and Siri can control the app with the URLs `zweiklang://start`, `zweiklang://stop` and `zweiklang://toggle` ("Open URL" action).

## Good to know

- AirPods in their closed case cannot play sound. Take them out before you start.
- AirPods switch automatically between Apple devices. If your friend's iPhone starts playing something, their AirPods may jump back to it; click **Reconnect** in the menu.
- Don't use the AirPods' microphone during a film: macOS then switches them to lower phone-call quality.
- Your own multi-output devices in Audio MIDI Setup stay untouched. Zweiklang creates its own while you listen together and removes it afterwards.

## Uninstall

Quit Zweiklang from its menu, then move it from Applications to the Trash. To also forget its settings: `defaults delete ch.moritz.zweiklang`.

## Build from source

Needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
scripts/build-and-install.sh      # test, build, sign, install to /Applications
scripts/release.sh                # signed and notarized build/Zweiklang.dmg (maintainer)
```

Details for contributors and AI agents: [AGENTS.md](AGENTS.md).

## Auf Deutsch

Zweiklang spielt den Ton des Mac gleichzeitig auf zwei AirPods ab, mit einem eigenen Lautstärkeregler pro Paar. Installieren: [Zweiklang.dmg](https://github.com/Mooned8/zweiklang/releases/latest/download/Zweiklang.dmg) laden, öffnen, Zweiklang in «Programme» ziehen und starten. Die App übernimmt die Systemsprache des Mac.

## License

[MIT](LICENSE) © 2026 Moritz Krummenacher
