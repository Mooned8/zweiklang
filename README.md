# Zweiklang

**Two AirPods, one Mac, one film.** Zweiklang is a small menu bar app for macOS that plays your Mac's sound on several outputs at the same time, each with its own volume slider. Two pairs of AirPods for watching a film together is the main use case, but any mix works: Bluetooth headphones, wired headphones, USB DACs and speakers. No more fiddling in Audio MIDI Setup.

<img src="docs/screenshot.png" width="300" alt="Zweiklang menu with one volume slider per output and the timing section open">

- **Any outputs at once:** AirPods and other Bluetooth headphones, wired headphones, USB DACs, speakers. Two or more, add and remove them in the menu.
- **One click:** connects the AirPods and switches the Mac's sound to all chosen outputs. "Stop listening together" brings back the previous output.
- **Easy connecting:** when the menu opens, the chosen AirPods connect in the background. Each pair shows its battery and whether it is still in the case. If a pair jumps back to an iPhone, Zweiklang fetches it back.
- **Volume:** one slider per output, optionally linked. The keyboard volume keys change all outputs at once, with a small on-screen display (also over full-screen video).
- **Timing:** Zweiklang evens out the delays the devices report, and shows per output how much it adds automatically, how much you added and why. Fine-tune by ear in 5 ms steps; saved per device.
- **Guests:** when you stop, your friends' AirPods are released so they go back to their iPhones.
- **Updates:** Zweiklang looks for a new version once a day and installs it with one click (gear icon: "Check for updates …").
- **Languages:** English, German, Spanish, French, Italian, Dutch and Portuguese, following the Mac's language.

## Install

1. Download **[Zweiklang.dmg](https://github.com/Mooned8/zweiklang/releases/latest/download/Zweiklang.dmg)** (latest release).
2. Open it and drag **Zweiklang** into **Applications**.
3. Open Zweiklang from Applications. An AirPods icon appears in the menu bar, and a window with the same controls opens.

**Can't see the icon?** On small screens a full menu bar can hide it (for example behind the notch). Open Zweiklang again from Applications or Spotlight: the window with all controls appears.

Requires macOS 14 Sonoma or later, on Apple silicon or Intel. The app is signed and notarized by Apple.

### Install with your AI agent

Tell your coding agent (Claude Code, Codex, …):

> Install the Mac app Zweiklang for me from https://github.com/Mooned8/zweiklang. Follow the instructions in its AGENTS.md.

## How to use

1. Pair both AirPods with the Mac once (System Settings > Bluetooth, or **Pair new AirPods …** in the headphone list). Your friend's AirPods only need this the first time.
2. Take both pairs out of their cases.
3. Click the AirPods icon in the menu bar, pick the two pairs and click **Listen together**. **Add output** adds more headphones or speakers.
4. Adjust each output with its slider. **Stop listening together** ends it.
5. Open **Timing** to see how much each output is delayed automatically and why. If one still plays ahead, delay it in steps of 5 ms until the sound is in sync.

On first launch macOS asks whether Zweiklang may use Bluetooth: click **Allow**.
For the volume keys, click **Allow …** in the menu once and switch Zweiklang on under System Settings > Privacy & Security > Accessibility. The gear icon turns this off if you do not want it.

Shortcuts and Siri can control the app with the URLs `zweiklang://open`, `zweiklang://start`, `zweiklang://stop` and `zweiklang://toggle` ("Open URL" action).

## How many people can listen?

Zweiklang has no fixed limit on outputs. The limit is Bluetooth:

- **Two pairs of Bluetooth headphones** (e.g. AirPods) work well. This is what Zweiklang is made for.
- **A third Bluetooth pair** often works, but can drop out. All Bluetooth headphones share the Mac's one Bluetooth radio, and each needs a continuous audio stream. Four or more Bluetooth pairs are not practical.
- **Wired outputs don't count against that limit:** the headphone jack (with a splitter, two people can share it), USB DACs and headphone amps, USB or HDMI speakers. Four or five people work with, for example, two pairs of AirPods plus wired headphones.

## Good to know

- AirPods in their closed case cannot play sound. Take them out before you start.
- When the menu opens, Zweiklang connects the chosen AirPods in the background, so listening starts at once. Below each pair it shows whether it is connected, still in the case or not reachable, and its battery. This can pull your friend's AirPods away from their iPhone; the gear icon switches it off ("Connect when the menu opens").
- AirPods switch automatically between Apple devices. If your friend's iPhone starts playing something, their AirPods may jump back to it; Zweiklang fetches them back up to three times, then shows **Reconnect**.
- When you stop listening together, Zweiklang disconnects your friends' AirPods (every pair after the first in the list) so they can go back to their iPhones (gear icon: "Release guest AirPods when stopping").
- Don't use the AirPods' microphone during a film: macOS then switches them to lower phone-call quality.
- macOS already lines up the outputs by the delay each device reports. Bluetooth headphones are often a little later than they report; that rest is what the Timing sliders are for.
- Updates come from this page and are checked twice: signed by the developer (Sparkle) and notarized by Apple. Version 1.4 and older have no update function yet; install 1.5 once by hand.
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

Zweiklang spielt den Ton des Mac gleichzeitig auf mehreren Ausgängen ab, jeder mit eigenem Lautstärkeregler. Gedacht vor allem für zwei AirPods beim gemeinsamen Filmschauen, es geht aber mit allen Ausgängen: Bluetooth-Kopfhörer, Kopfhörer mit Kabel, USB-DACs, Lautsprecher. Ein Zeitabgleich sorgt dafür, dass alle gleichzeitig klingen. Zwei Bluetooth-Kopfhörer laufen zuverlässig, ein drittes Paar kann aussetzen; mehr Leute gehen mit zusätzlichen Kopfhörern am Kabel oder an einem USB-DAC. Installieren: [Zweiklang.dmg](https://github.com/Mooned8/zweiklang/releases/latest/download/Zweiklang.dmg) laden, öffnen, Zweiklang in «Programme» ziehen und starten. Die App übernimmt die Systemsprache des Mac. Siehst du das Symbol in der Menüleiste nicht, öffne Zweiklang nochmals, dann erscheint ein Fenster mit allen Reglern. Neue Versionen holt sich die App selbst (Zahnrad: «Nach Updates suchen …»).

## License

[MIT](LICENSE) © 2026 Moritz Krummenacher
