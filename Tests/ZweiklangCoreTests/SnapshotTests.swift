import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import ZweiklangCore

/// Renders the menu window to PNG files for a visual check.
/// Runs only with TEST_RUNNER_ZWEIKLANG_SNAPSHOT_DIR=<folder> set for xcodebuild.
@MainActor
final class SnapshotTests: XCTestCase {
    private let testUID = "ch.moritz.zweiklang.snapshot-test"

    private func render<V: View>(_ view: V, to name: String, in directory: String, dark: Bool = false) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testRenderMenuStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["ZWEIKLANG_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_ZWEIKLANG_SNAPSHOT_DIR to render")
        }
        let suite = "zweiklang-snapshot-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let bluetooth = StubBluetooth()
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.preconnectEnabled = false // calm, repeatable pictures
        let options = AppOptions(defaults: defaults, controller: controller)
        let menu = MenuContentView(controller: controller, options: options, onQuit: {})
        try render(menu, to: "1-bereit.png", in: directory)
        try render(MenuContentView(controller: controller, options: options, onQuit: {},
                                   showsTiming: false, showsPairingHelp: true),
                   to: "1c-koppeln-hinweis.png", in: directory)
        // TEST_RUNNER_ZWEIKLANG_SNAPSHOT_IDLE_ONLY=1: stop here, before anything touches the sound output.
        if ProcessInfo.processInfo.environment["ZWEIKLANG_SNAPSHOT_IDLE_ONLY"] != nil { return }
        controller.addOutput(OutputTarget(name: "Carla’s AirPods", bluetoothAddress: "AA-BB-CC-DD-EE-03"))
        try render(menu, to: "1b-drei-ausgaenge.png", in: directory)
        controller.removeOutput(slot: 2)

        controller.connectTimeout = 0.1
        await controller.start()
        try render(menu, to: "2-fehler.png", in: directory)

        // Bluetooth link without sound: AirPods in the case, with battery.
        controller.dismissMessage()
        bluetooth.linkComes = true
        controller.audioAppearTimeout = 0.1
        controller.preconnectEnabled = true
        controller.menuOpened()
        let deadline = Date().addingTimeInterval(3)
        while controller.slotBattery.contains(nil), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        controller.preconnectEnabled = false
        try render(menu, to: "2b-im-case.png", in: directory)

        // Active session on BlackHole + muted speakers, named like the real AirPods.
        let a = try XCTUnwrap(AudioSystem.device(uid: VirtualDevices.first))
        let b = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
        let speakerMute = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        let muteBefore = HAL.value(b.id, speakerMute, initial: UInt32(0)) ?? 0
        let outputBefore = try XCTUnwrap(AudioSystem.defaultOutputDeviceID())
        let volumesBefore = [Volume.get(a.id), Volume.get(b.id)]
        defer {
            controller.stop()
            if AudioSystem.defaultOutputDeviceID() != outputBefore { try? AudioSystem.setDefaultOutputDevice(outputBefore) }
            if let v = volumesBefore[0] { try? Volume.set(v, on: a.id) }
            if let v = volumesBefore[1] { try? Volume.set(v, on: b.id) }
            try? HAL.setValue(b.id, speakerMute, muteBefore, operation: "unmute")
        }
        try HAL.setValue(b.id, speakerMute, UInt32(1), operation: "mute")
        controller.select(OutputTarget(name: "Anna’s AirPods Pro", deviceUID: a.uid), slot: 0)
        controller.select(OutputTarget(name: "Ben’s AirPods Pro", deviceUID: b.uid), slot: 1)
        await controller.start()
        XCTAssertEqual(controller.phase, .active)
        controller.setVolume(0.65, slot: 0)
        controller.setVolume(0.4, slot: 1)
        try render(menu, to: "3-aktiv.png", in: directory)
        try render(VolumeHUDView(controller: controller), to: "4-tasten-anzeige.png", in: directory)
        controller.setSyncOffset(40, slot: 1)
        try render(MenuContentView(controller: controller, options: options, onQuit: {}, showsTiming: true),
                   to: "5-zeitabgleich.png", in: directory)

        // Every language once, to spot texts that do not fit.
        let original = Bundle.zweiklang
        defer { Bundle.zweiklang = original }
        for language in ["en", "de", "es", "fr", "it", "nl", "pt"] {
            let path = try XCTUnwrap(original.path(forResource: language, ofType: "lproj"))
            Bundle.zweiklang = try XCTUnwrap(Bundle(path: path))
            try render(MenuContentView(controller: controller, options: options, onQuit: {}, showsTiming: true),
                       to: "sprache-\(language).png", in: directory)
        }

        // Screenshot for the README, with friendly names.
        // Last, because it switches the volume-key option off (the test runner has no permission anyway).
        options.setMediaKeysEnabled(false)
        // BlackHole stands in for headphones on a USB DAC: like those it has no own sound processing,
        // so it waits for the built-in speakers, which is what the timing section explains.
        controller.displayNameOverrides = [0: "Headphones (USB DAC)", 1: "MacBook Pro Speakers"]
        controller.setSyncOffset(0, slot: 0)
        controller.setSyncOffset(0, slot: 1)
        let english = try XCTUnwrap(Bundle(path: try XCTUnwrap(original.path(forResource: "en", ofType: "lproj"))))
        let previous = Bundle.zweiklang
        Bundle.zweiklang = english
        try render(MenuContentView(controller: controller, options: options, onQuit: {}, showsTiming: true),
                   to: "readme-screenshot.png", in: directory)
        Bundle.zweiklang = previous
        controller.displayNameOverrides = [:]
    }
}
