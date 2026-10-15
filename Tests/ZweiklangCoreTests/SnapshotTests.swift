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

        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        let options = AppOptions(defaults: defaults, controller: controller)
        let menu = MenuContentView(controller: controller, options: options, onQuit: {})
        try render(menu, to: "1-bereit.png", in: directory)

        controller.connectTimeout = 0.1
        await controller.start()
        try render(menu, to: "2-fehler.png", in: directory)

        // Active session on BlackHole + muted speakers, named like the real AirPods.
        let a = try XCTUnwrap(AudioSystem.device(uid: VirtualDevices.first))
        let b = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
        let speakerMute = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        let muteBefore = HAL.value(b.id, speakerMute, initial: UInt32(0)) ?? 0
        try HAL.setValue(b.id, speakerMute, UInt32(1), operation: "mute")
        let outputBefore = try XCTUnwrap(AudioSystem.defaultOutputDeviceID())
        let volumesBefore = [Volume.get(a.id), Volume.get(b.id)]
        defer {
            controller.stop()
            if AudioSystem.defaultOutputDeviceID() != outputBefore { try? AudioSystem.setDefaultOutputDevice(outputBefore) }
            if let v = volumesBefore[0] { try? Volume.set(v, on: a.id) }
            if let v = volumesBefore[1] { try? Volume.set(v, on: b.id) }
            try? HAL.setValue(b.id, speakerMute, muteBefore, operation: "unmute")
        }
        controller.select(OutputTarget(name: "Anna’s AirPods Pro", deviceUID: a.uid), slot: 0)
        controller.select(OutputTarget(name: "Ben’s AirPods Pro", deviceUID: b.uid), slot: 1)
        await controller.start()
        XCTAssertEqual(controller.phase, .active)
        controller.setVolume(0.65, slot: 0)
        controller.setVolume(0.4, slot: 1)
        try render(menu, to: "3-aktiv.png", in: directory)
        try render(VolumeHUDView(controller: controller), to: "4-tasten-anzeige.png", in: directory)

        // Every language once, to spot texts that do not fit.
        let original = Bundle.zweiklang
        defer { Bundle.zweiklang = original }
        for language in ["en", "de", "es", "fr", "it", "nl", "pt"] {
            let path = try XCTUnwrap(original.path(forResource: language, ofType: "lproj"))
            Bundle.zweiklang = try XCTUnwrap(Bundle(path: path))
            try render(MenuContentView(controller: controller, options: options, onQuit: {}),
                       to: "sprache-\(language).png", in: directory)
        }

        // Screenshot for the README, with friendly names.
        // Last, because it switches the volume-key option off (the test runner has no permission anyway).
        options.setMediaKeysEnabled(false)
        controller.displayNameOverrides = [0: "Anna’s AirPods Pro", 1: "Ben’s AirPods"]
        let english = try XCTUnwrap(Bundle(path: try XCTUnwrap(original.path(forResource: "en", ofType: "lproj"))))
        let previous = Bundle.zweiklang
        Bundle.zweiklang = english
        try render(menu, to: "readme-screenshot.png", in: directory)
        Bundle.zweiklang = previous
        controller.displayNameOverrides = [:]
    }
}
