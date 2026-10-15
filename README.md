# Zweiklang

**Two AirPods, one Mac, one film.** Zweiklang is a small menu bar app for macOS that plays your Mac's sound on two pairs of AirPods at the same time, each with its own volume slider. No more fiddling in Audio MIDI Setup.

<img src="docs/screenshot.png" width="300" alt="Zweiklang menu with one volume slider per pair of AirPods">

- Connects both pairs of AirPods with one click and switches the Mac's sound to both.
- More than two outputs: add a third pair of headphones or the speakers, each with its own slider.
- Timing: if one output plays ahead (e.g. speakers next to Bluetooth headphones), delay it until everything is in sync. The setting is saved per device.
- One volume slider per pair, optionally linked.
- The keyboard volume keys change all outputs at once (with a small on-screen display, also over full-screen video).
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

1. Pair both AirPods with the Mac once (System Settings > Bluetooth, or **Pair new AirPods …** in the headphone list). Your friend's AirPods only need this the first time.
2. Take both pairs out of their cases.
3. Click the AirPods icon in the menu bar, pick the two pairs and click **Listen together**. **Add output** adds more headphones or speakers.
4. Adjust each output with its slider. **Stop listening together** ends it.
5. If one output plays ahead, open **Timing** and delay it in steps of 5 ms until the sound is in sync.

On first launch macOS asks whether Zweiklang may use Bluetooth: click **Allow**.
For the volume keys, click **Allow …** in the menu once and switch Zweiklang on under System Settings > Privacy & Security > Accessibility. The gear icon turns this off if you do not want it.

Shortcuts and Siri can control the app with the URLs `zweiklang://start`, `zweiklang://stop` and `zweiklang://toggle` ("Open URL" action).

## Good to know

- AirPods in their closed case cannot play sound. Take them out before you start.
- When the menu opens, Zweiklang connects the chosen AirPods in the background, so listening starts at once. Below each pair it shows whether it is connected, still in the case or not reachable, and its battery. This can pull your friend's AirPods away from their iPhone; the gear icon switches it off ("Connect when the menu opens").
- AirPods switch automatically between Apple devices. If your friend's iPhone starts playing something, their AirPods may jump back to it; Zweiklang fetches them back up to three times, then shows **Reconnect**.
- When you stop listening together, Zweiklang disconnects your friends' AirPods (every pair after the first in the list) so they can go back to their iPhones (gear icon: "Release guest AirPods when stopping").
- Don't use the AirPods' microphone during a film: macOS then switches them to lower phone-call quality.
- More than two Bluetooth headphones on one Mac can cause dropouts: they share one Bluetooth radio.
- macOS already lines up the outputs by the delay each device reports. Bluetooth headphones are often a little later than they report; that rest is what the Timing sliders are for.
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

Zweiklang spielt den Ton des Mac gleichzeitig auf zwei AirPods ab (oder auf mehr Kopfhörern und Lautsprechern), mit einem eigenen Lautstärkeregler pro Gerät und einem Zeitabgleich, damit alle gleichzeitig klingen. Weitere Kopfhörer oder Lautsprecher lassen sich dazunehmen; spielt einer zu früh, lässt er sich unter «Zeitabgleich» verzögern. Installieren: [Zweiklang.dmg](https://github.com/Mooned8/zweiklang/releases/latest/download/Zweiklang.dmg) laden, öffnen, Zweiklang in «Programme» ziehen und starten. Die App übernimmt die Systemsprache des Mac.

## License

[MIT](LICENSE) © 2026 Moritz Krummenacher
