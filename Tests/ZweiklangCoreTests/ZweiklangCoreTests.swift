import CoreAudio
import XCTest
@testable import ZweiklangCore

// MARK: - Pure logic

final class BluetoothAddressTests: XCTestCase {
    func testNormalizesBothNotations() {
        XCTAssertEqual(BluetoothAddress.normalized("12:34:56:78:9A:BC"), "123456789abc")
        XCTAssertEqual(BluetoothAddress.normalized("12-34-56-78-9a-bc"), "123456789abc")
    }

    func testMatchesCoreAudioUIDOfAirPods() {
        XCTAssertTrue(BluetoothAddress.matches(deviceUID: "12-34-56-78-9A-BC:output", address: "12:34:56:78:9a:bc"))
        XCTAssertTrue(BluetoothAddress.matches(deviceUID: "12-34-56-78-9A-BC:input", address: "12-34-56-78-9A-BC"))
        XCTAssertFalse(BluetoothAddress.matches(deviceUID: "12-34-56-78-9A-BD:output", address: "12-34-56-78-9A-BC"))
        XCTAssertFalse(BluetoothAddress.matches(deviceUID: "BuiltInSpeakerDevice", address: "12-34-56-78-9A-BC"))
        XCTAssertFalse(BluetoothAddress.matches(deviceUID: "x12-34-56-78-9A-BC:output", address: "12-34-56-78-9A-BC"))
    }

    func testReadsAddressFromDeviceUID() {
        XCTAssertEqual(BluetoothAddress.fromDeviceUID("12-34-56-78-9a-bd:output"), "12-34-56-78-9A-BD")
        XCTAssertNil(BluetoothAddress.fromDeviceUID("BlackHole2ch_UID"))
        XCTAssertNil(BluetoothAddress.fromDeviceUID("AppleUSBAudioEngine:FIIO:FiiO K11 R2R:2113000:2"))
    }
}

final class OutputTargetTests: XCTestCase {
    private func device(uid: String, channels: Int = 2, transport: UInt32 = kAudioDeviceTransportTypeBluetooth) -> AudioDevice {
        AudioDevice(id: 1, uid: uid, name: "x", transportType: transport, outputChannels: channels)
    }

    func testBluetoothTargetMatchesOnlyOutputSide() {
        let target = OutputTarget(name: "AirPods", bluetoothAddress: "12-34-56-78-9A-BC")
        XCTAssertTrue(target.matches(device(uid: "12-34-56-78-9A-BC:output")))
        XCTAssertFalse(target.matches(device(uid: "12-34-56-78-9A-BC:input", channels: 0)))
        XCTAssertFalse(target.matches(device(uid: "12-34-56-78-9A-BC:output", transport: kAudioDeviceTransportTypeAggregate)))
    }

    func testIdentityIgnoresAddressNotation() {
        XCTAssertEqual(OutputTarget(name: "a", bluetoothAddress: "12:34:56:78:9A:BC").id,
                       OutputTarget(name: "b", bluetoothAddress: "12-34-56-78-9a-bc").id)
        XCTAssertNotEqual(OutputTarget(name: "a", deviceUID: "A").id, OutputTarget(name: "a", deviceUID: "B").id)
    }
}

final class MediaKeyParsingTests: XCTestCase {
    private func data1(key: Int, down: Bool, repeating: Bool = false) -> Int {
        (key << 16) | ((down ? 0xA : 0xB) << 8) | (repeating ? 1 : 0)
    }

    func testParsesVolumeKeys() {
        XCTAssertEqual(MediaKeyTap.parse(data1: data1(key: 0, down: true), flags: []),
                       MediaKeyEvent(key: .volumeUp, isDown: true, isRepeat: false, isFine: false))
        XCTAssertEqual(MediaKeyTap.parse(data1: data1(key: 1, down: false), flags: [])?.key, .volumeDown)
        XCTAssertEqual(MediaKeyTap.parse(data1: data1(key: 7, down: true, repeating: true), flags: [])?.isRepeat, true)
        XCTAssertEqual(MediaKeyTap.parse(data1: data1(key: 0, down: true), flags: [.maskAlternate, .maskShift])?.isFine, true)
    }

    func testIgnoresOtherKeys() {
        XCTAssertNil(MediaKeyTap.parse(data1: data1(key: 16, down: true), flags: [])) // play/pause
        XCTAssertNil(MediaKeyTap.parse(data1: data1(key: 2, down: true), flags: [])) // brightness
    }
}

// MARK: - Real Core Audio (virtual devices only)

/// Two virtual outputs installed on this Mac. They make no sound, so the tests are silent.
enum VirtualDevices {
    static let first = "BlackHole2ch_UID"
    static let second = "MSLoopbackDriverDevice_UID"

    static func require() throws -> (AudioDevice, AudioDevice) {
        AudioSystem.configure()
        guard let a = AudioSystem.device(uid: first), let b = AudioSystem.device(uid: second) else {
            throw XCTSkip("BlackHole 2ch and Microsoft Teams Audio are needed for the Core Audio tests")
        }
        return (a, b)
    }
}

final class CoreAudioTests: XCTestCase {
    private let testUID = "ch.moritz.zweiklang.test-\(UUID().uuidString)"

    override func tearDown() {
        if let leftover = AudioSystem.device(uid: testUID) { try? MultiOutputDevice.destroy(leftover.id) }
    }

    func testListsOutputDevices() throws {
        let (a, _) = try VirtualDevices.require()
        let outputs = AudioSystem.outputDevices()
        XCTAssertTrue(outputs.contains { $0.uid == a.uid })
        XCTAssertFalse(outputs.contains { $0.isAggregate })
        XCTAssertNotNil(AudioSystem.defaultOutputDeviceID())
    }

    func testVolumeRoundTripRestoresOriginal() throws {
        let (a, _) = try VirtualDevices.require()
        XCTAssertTrue(Volume.canControl(a.id))
        let original = try XCTUnwrap(Volume.get(a.id))
        defer { try? Volume.set(original, on: a.id) }
        try Volume.set(0.25, on: a.id)
        XCTAssertEqual(try XCTUnwrap(Volume.get(a.id)), 0.25, accuracy: 0.02)
        try Volume.set(1.4, on: a.id) // clamped
        XCTAssertEqual(try XCTUnwrap(Volume.get(a.id)), 1, accuracy: 0.02)
    }

    func testCreatesMultiOutputThatMirrorsAudioAndRemovesIt() async throws {
        let (a, b) = try VirtualDevices.require()
        let device = try await MultiOutputDevice.create(subDeviceUIDs: [a.uid, b.uid], uid: testUID, name: "Zweiklang Test")
        XCTAssertTrue(device.isAggregate)
        XCTAssertTrue(MultiOutputDevice.isStacked(device.id))
        XCTAssertEqual(MultiOutputDevice.subDeviceUIDs(device.id), [a.uid, b.uid])
        // Multi-output: every sub-device gets the same stream, so the device has as many
        // channels as its widest member (2), not the sum (3) as a combining aggregate would.
        XCTAssertEqual(device.outputChannels, max(a.outputChannels, b.outputChannels))
        let subs = MultiOutputDevice.composition(device.id)[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        XCTAssertEqual(subs?.map { $0[kAudioSubDeviceDriftCompensationKey] as? Int }, [0, 1])

        try MultiOutputDevice.destroy(device.id)
        XCTAssertNil(AudioSystem.device(uid: testUID))
    }
}

// MARK: - Session flow with virtual devices

@MainActor
final class StubBluetooth: BluetoothProviding {
    var connectCalls: [String] = []
    func pairedHeadphones() -> [BluetoothHeadphone] {
        [BluetoothHeadphone(address: "AA-BB-CC-DD-EE-01", name: "AirPods Test A"),
         BluetoothHeadphone(address: "AA-BB-CC-DD-EE-02", name: "AirPods Test B")]
    }
    func connect(address: String, timeout: TimeInterval) async -> Bool {
        connectCalls.append(address)
        return false
    }
}

/// Holds the first connect call open until the test releases it.
@MainActor
final class SuspendingBluetooth: BluetoothProviding {
    private var held: CheckedContinuation<Bool, Never>?
    func pairedHeadphones() -> [BluetoothHeadphone] { StubBluetooth().pairedHeadphones() }
    func connect(address: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            if held == nil { held = continuation } else { continuation.resume(returning: false) }
        }
    }
    func release() { held?.resume(returning: true); held = nil }
}

@MainActor
final class SessionControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let testUID = "ch.moritz.zweiklang.session-test"

    override func setUp() async throws {
        suiteName = "zweiklang-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let leftover = AudioSystem.device(uid: testUID) { try? MultiOutputDevice.destroy(leftover.id) }
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPicksTwoAirPodsByDefaultAndListsOtherOutputs() {
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        XCTAssertEqual(controller.targets.compactMap { $0?.name }, ["AirPods Test A", "AirPods Test B"])
        XCTAssertTrue(controller.candidates.contains { $0.deviceUID == "BuiltInSpeakerDevice" })
        XCTAssertFalse(controller.candidates.contains { $0.deviceUID == VirtualDevices.second }) // cannot be system output
        XCTAssertEqual(controller.slotDevices.compactMap { $0 }.count, 0)
    }

    func testRefusesSameDeviceTwice() async {
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        let target = OutputTarget(name: "BlackHole", deviceUID: VirtualDevices.first)
        controller.select(target, slot: 0)
        controller.select(target, slot: 1)
        await controller.start()
        XCTAssertEqual(controller.phase, .failed(L("Please choose two different headphones.")))
    }

    func testStopWhileConnectingCancelsTheStart() async throws {
        let bluetooth = SuspendingBluetooth()
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        let outputBefore = AudioSystem.defaultOutputDeviceID()
        let start = Task { await controller.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(controller.isWorking)
        controller.stop()
        XCTAssertEqual(controller.phase, .idle)
        bluetooth.release()
        await start.value
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(AudioSystem.device(uid: testUID))
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), outputBefore)
    }

    func testFailsCleanlyWhenHeadphonesDoNotConnect() async {
        let bluetooth = StubBluetooth()
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.connectTimeout = 0.1
        let outputBefore = AudioSystem.defaultOutputDeviceID()
        await controller.start()
        guard case .failed(let message) = controller.phase else { return XCTFail("expected failure, got \(controller.phase)") }
        XCTAssertTrue(message.contains("AirPods Test A"))
        XCTAssertEqual(Set(bluetooth.connectCalls), ["AA-BB-CC-DD-EE-01", "AA-BB-CC-DD-EE-02"])
        XCTAssertNil(AudioSystem.device(uid: testUID))
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), outputBefore)
    }

    /// Switches the system output for a moment and restores it. Uses BlackHole plus the built-in
    /// speakers (muted for the duration, Teams Audio cannot be the system output), so nothing is heard.
    func testFullSessionSwitchesOutputControlsVolumesAndRestores() async throws {
        let (a, _) = try VirtualDevices.require()
        let b = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
        let speakerMute = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        let speakerMuteBefore = try XCTUnwrap(HAL.value(b.id, speakerMute, initial: UInt32(0)))
        try HAL.setValue(b.id, speakerMute, UInt32(1), operation: "mute speakers")
        let outputBefore = try XCTUnwrap(AudioSystem.defaultOutputDeviceID())
        let volumesBefore = [Volume.get(a.id), Volume.get(b.id)]
        defer {
            if AudioSystem.defaultOutputDeviceID() != outputBefore { try? AudioSystem.setDefaultOutputDevice(outputBefore) }
            if let v = volumesBefore[0] { try? Volume.set(v, on: a.id) }
            if let v = volumesBefore[1] { try? Volume.set(v, on: b.id) }
            try? HAL.setValue(b.id, speakerMute, speakerMuteBefore, operation: "restore speaker mute")
        }

        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        controller.select(OutputTarget(name: a.name, deviceUID: a.uid), slot: 0)
        controller.select(OutputTarget(name: b.name, deviceUID: b.uid), slot: 1)
        await controller.start()
        XCTAssertEqual(controller.phase, .active)
        let aggregate = try XCTUnwrap(AudioSystem.device(uid: testUID))
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), aggregate.id)
        XCTAssertTrue(controller.isSelectedAsOutput)

        // Independent sliders
        controller.setVolume(0.3, slot: 0)
        controller.setVolume(0.8, slot: 1)
        XCTAssertEqual(try XCTUnwrap(Volume.get(a.id)), 0.3, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(Volume.get(b.id)), 0.8, accuracy: 0.02)

        // Linked sliders keep the difference
        controller.linked = true
        controller.setVolume(0.4, slot: 0)
        XCTAssertEqual(try XCTUnwrap(Volume.get(b.id)), 0.9, accuracy: 0.02)
        controller.linked = false

        // Volume keys: same step on both, swallowed
        let up = MediaKeyEvent(key: .volumeUp, isDown: true, isRepeat: false, isFine: false)
        XCTAssertTrue(controller.handleMediaKey(up))
        XCTAssertEqual(try XCTUnwrap(Volume.get(a.id)), 0.4 + 1 / 16, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(Volume.get(b.id)), 0.9 + 1 / 16, accuracy: 0.02)
        XCTAssertTrue(controller.handleMediaKey(MediaKeyEvent(key: .volumeUp, isDown: false, isRepeat: false, isFine: false)))

        // Mute and unmute bring the old levels back
        let mute = MediaKeyEvent(key: .mute, isDown: true, isRepeat: false, isFine: false)
        XCTAssertTrue(controller.handleMediaKey(mute))
        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(try XCTUnwrap(Volume.get(a.id)), 0, accuracy: 0.01)
        XCTAssertTrue(controller.handleMediaKey(mute))
        XCTAssertFalse(controller.isMuted)
        XCTAssertEqual(try XCTUnwrap(Volume.get(a.id)), 0.4 + 1 / 16, accuracy: 0.02)

        // Turned up elsewhere while muted: no longer muted
        XCTAssertTrue(controller.handleMediaKey(mute))
        XCTAssertTrue(controller.isMuted)
        try Volume.set(0.5, on: a.id)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(controller.isMuted)
        XCTAssertEqual(controller.volumes[0], 0.5, accuracy: 0.02)

        // An outside volume change (e.g. on the AirPods stem) shows up in the slider
        try Volume.set(0.15, on: b.id)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.volumes[1], 0.15, accuracy: 0.02)

        // Another app/user picks a different output: keys are no longer ours
        try AudioSystem.setDefaultOutputDevice(outputBefore)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(controller.isSelectedAsOutput)
        XCTAssertFalse(controller.handleMediaKey(up))
        controller.selectAsOutput()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(controller.isSelectedAsOutput)

        // A failed reconnect keeps the running session and only shows a notice
        let original = controller.targets[1]
        controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 1)
        controller.connectTimeout = 0.1
        let reconnect = Task { await controller.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.phase, .active) // sliders and keys stay usable while reconnecting
        XCTAssertTrue(controller.isReconnecting)
        await reconnect.value
        XCTAssertEqual(controller.phase, .active)
        XCTAssertFalse(controller.isReconnecting)
        XCTAssertNotNil(controller.message)
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), aggregate.id)

        // Mute works with one pair disconnected, and gives the connected pair its level back
        let levelA = controller.volumes[0]
        XCTAssertTrue(controller.handleMediaKey(mute))
        XCTAssertTrue(controller.isMuted)
        XCTAssertTrue(controller.handleMediaKey(mute))
        XCTAssertFalse(controller.isMuted)
        XCTAssertEqual(try XCTUnwrap(Volume.get(a.id)), levelA, accuracy: 0.02)
        controller.select(original, slot: 1)
        controller.dismissMessage()

        // Relaunch adopts the running session
        let relaunched = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        relaunched.recoverOnLaunch()
        XCTAssertEqual(relaunched.phase, .active)

        controller.stop()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(AudioSystem.device(uid: testUID))
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), outputBefore)
    }

    func testReportsOutputThatMacOSRefuses() async throws {
        let (a, b) = try VirtualDevices.require() // Teams Audio cannot be the system output
        let outputBefore = AudioSystem.defaultOutputDeviceID()
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        controller.select(OutputTarget(name: a.name, deviceUID: a.uid), slot: 0)
        controller.select(OutputTarget(name: b.name, deviceUID: b.uid), slot: 1)
        await controller.start()
        guard case .failed = controller.phase else { return XCTFail("expected failure, got \(controller.phase)") }
        XCTAssertNil(AudioSystem.device(uid: testUID))
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), outputBefore)
    }

    func testStaleDeviceFromCrashIsRemovedOnLaunch() async throws {
        let (a, b) = try VirtualDevices.require()
        try await MultiOutputDevice.create(subDeviceUIDs: [a.uid, b.uid], uid: testUID)
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        controller.recoverOnLaunch() // not the system output and slots are the stub AirPods -> clean up
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(AudioSystem.device(uid: testUID))
    }
}

// MARK: - Translations

final class LocalizationTests: XCTestCase {
    private func table(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.zweiklang.url(forResource: "Localizable", withExtension: "strings",
                                                     subdirectory: nil, localization: language), language)
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
    }

    private func placeholderCount(_ text: String) -> Int {
        text.components(separatedBy: "%").count - 1
    }

    func testEveryLanguageHasEveryTextWithMatchingPlaceholders() throws {
        let english = try table("en")
        XCTAssertGreaterThan(english.count, 30)
        for language in ["de", "es", "fr", "it", "nl", "pt"] {
            let translated = try table(language)
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
            for (key, value) in translated {
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(placeholderCount(value), placeholderCount(key), "\(language): \(key)")
            }
        }
    }

    func testMessagesWithNamesAreFilledIn() throws {
        let path = try XCTUnwrap(Bundle.zweiklang.path(forResource: "de", ofType: "lproj"))
        let german = try XCTUnwrap(Bundle(path: path))
        let message = String(localized: "“\("A")” and “\("B")” could not be connected. Take the AirPods out of the case, hold them near the Mac and try again.", bundle: german)
        XCTAssertTrue(message.hasPrefix("«A» und «B» liessen sich nicht verbinden."), message)
    }
}
