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

final class BatteryReportTests: XCTestCase {
    /// Shape of `system_profiler -json SPBluetoothDataType` on macOS 26, addresses made up.
    private let sample = Data("""
    {"SPBluetoothDataType": [{
      "controller_properties": {"controller_state": "attrib_on"},
      "device_connected": [
        {"Anna’s AirPods Pro": {"device_address": "74:15:F5:00:00:01", "device_batteryLevelCase": "40%",
                                "device_batteryLevelLeft": "100%", "device_batteryLevelRight": "98%"}},
        {"AirPods Max": {"device_address": "74:15:F5:00:00:02", "device_batteryLevelMain": "55%"}},
        {"MX Keys": {"device_address": "74:15:F5:00:00:03"}},
        {"Odd": {"device_address": "74:15:F5:00:00:04", "device_batteryLevelLeft": "n/a"}}
      ],
      "device_not_connected": [
        {"Ben’s AirPods": {"device_address": "74:15:F5:00:00:05", "device_batteryLevelLeft": "80%"}}
      ]
    }]}
    """.utf8)

    func testReadsEarbudsCaseAndSingleBatteries() {
        let levels = BatteryReport.parse(sample)
        XCTAssertEqual(levels["7415f5000001"], BatteryLevel(left: 100, right: 98, chargingCase: 40))
        XCTAssertEqual(levels["7415f5000001"]?.lowest, 98)
        XCTAssertEqual(levels["7415f5000002"]?.lowest, 55)
        XCTAssertNil(levels["7415f5000003"]) // no battery reported
        XCTAssertNil(levels["7415f5000004"]) // unreadable value
        XCTAssertNil(levels["7415f5000005"]) // not connected: stale values are ignored
    }

    func testUnexpectedOutputGivesNothing() {
        XCTAssertEqual(BatteryReport.parse(Data("not json".utf8)), [:])
        XCTAssertEqual(BatteryReport.parse(Data("{\"SPBluetoothDataType\": {}}".utf8)), [:])
        XCTAssertNil(BatteryReport.percent("140%"))
        XCTAssertEqual(BatteryReport.percent("7 %"), 7)
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testBudgetEndsTheTugOfWarAndRefillsAfterAStablePeriod() {
        var policy = ReconnectPolicy(delays: [3, 10, 30], refillAfter: 300)
        let start = Date()
        policy.pairPresent(at: start)
        XCTAssertTrue(policy.pairLost(at: start.addingTimeInterval(10)))
        XCTAssertEqual(policy.nextDelay, 3)
        XCTAssertEqual(policy.takeAttempt(), 1)
        XCTAssertEqual(policy.nextDelay, 10)
        XCTAssertEqual(policy.takeAttempt(), 2)
        // Back for a short while only: the budget is not refilled.
        policy.pairPresent(at: start.addingTimeInterval(60))
        XCTAssertTrue(policy.pairLost(at: start.addingTimeInterval(90)))
        XCTAssertEqual(policy.takeAttempt(), 3)
        XCTAssertNil(policy.nextDelay)
        XCTAssertNil(policy.takeAttempt())
        XCTAssertFalse(policy.pairLost(at: start.addingTimeInterval(100)))
        // Five quiet minutes later it may try again.
        policy.pairPresent(at: start.addingTimeInterval(200))
        XCTAssertTrue(policy.pairLost(at: start.addingTimeInterval(501)))
        XCTAssertEqual(policy.nextDelay, 3)
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

final class SyncDelaysTests: XCTestCase {
    func testAutomaticDelayEvensOutStreamLatency() {
        let speakers = OutputTiming(sampleRate: 44100, streamLatencyFrames: 639) // MacBook speaker DSP
        let airPods = OutputTiming(sampleRate: 48000, streamLatencyFrames: 0)
        let delays = SyncDelays.automatic([airPods, speakers, airPods])
        XCTAssertEqual(delays[0], 639 / 44.1, accuracy: 0.01)
        XCTAssertEqual(delays[1], 0)
        XCTAssertEqual(delays[2], delays[0])
        XCTAssertEqual(SyncDelays.automatic([airPods, airPods]), [0, 0])
        XCTAssertEqual(SyncDelays.automatic([]), [])
    }

    func testFramesUseTheDevicesOwnSampleRate() {
        XCTAssertEqual(SyncDelays.frames(milliseconds: 100, sampleRate: 48000), 4800)
        XCTAssertEqual(SyncDelays.frames(milliseconds: 100, sampleRate: 44100), 4410)
        XCTAssertEqual(SyncDelays.frames(milliseconds: -20, sampleRate: 48000), 0) // latency-out cannot advance
        XCTAssertEqual(SyncDelays.frames(milliseconds: 50, sampleRate: 0), 0)
        XCTAssertEqual(SyncDelays.frames(milliseconds: .nan, sampleRate: 48000), 0)
    }

    func testManualOffsetSnapsToStepsWithinRange() {
        XCTAssertEqual(SyncDelays.clampManual(42), 40)
        XCTAssertEqual(SyncDelays.clampManual(43), 45)
        XCTAssertEqual(SyncDelays.clampManual(-10), 0)
        XCTAssertEqual(SyncDelays.clampManual(9_000), SyncDelays.manualRange.upperBound)
        XCTAssertEqual(SyncDelays.clampManual(.infinity), 0)
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
        XCTAssertEqual(Set(MultiOutputDevice.activeSubDeviceUIDs(device.id)), [a.uid, b.uid])
        // Multi-output: every sub-device gets the same stream, so the device has as many
        // channels as its widest member (2), not the sum (3) as a combining aggregate would.
        XCTAssertEqual(device.outputChannels, max(a.outputChannels, b.outputChannels))
        let subs = MultiOutputDevice.composition(device.id)[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        XCTAssertEqual(subs?.map { $0[kAudioSubDeviceDriftCompensationKey] as? Int }, [0, 1])

        try MultiOutputDevice.destroy(device.id)
        XCTAssertNil(AudioSystem.device(uid: testUID))
    }

    /// Three sub-devices with their own delay; a delay changes in place while the device exists.
    func testDelaysAreSetPerSubDeviceAndChangeInPlace() async throws {
        let (a, b) = try VirtualDevices.require()
        let speakers = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
        let uids = [a.uid, b.uid, speakers.uid]
        let device = try await MultiOutputDevice.create(subDeviceUIDs: uids, extraLatencyFrames: [b.uid: 4800, speakers.uid: -5],
                                                        uid: testUID, name: "Zweiklang Test")
        XCTAssertEqual(MultiOutputDevice.subDeviceUIDs(device.id), uids)
        XCTAssertEqual(MultiOutputDevice.extraLatencyFrames(device.id), [a.uid: 0, b.uid: 4800, speakers.uid: 0])

        try MultiOutputDevice.setExtraLatency(device.id, frames: [a.uid: 2400, b.uid: 0])
        XCTAssertEqual(MultiOutputDevice.extraLatencyFrames(device.id), [a.uid: 2400, b.uid: 0, speakers.uid: 0])
        // Same device, same layout: nothing for the system output to lose.
        XCTAssertEqual(AudioSystem.device(uid: testUID)?.id, device.id)
        XCTAssertTrue(MultiOutputDevice.isStacked(device.id))
        XCTAssertEqual(MultiOutputDevice.subDeviceUIDs(device.id), uids)
        try MultiOutputDevice.destroy(device.id)
    }

    func testReadsStreamLatencyAndRate() throws {
        let speakers = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
        let timing = OutputTiming.read(speakers.id)
        XCTAssertGreaterThan(timing.sampleRate, 0)
        XCTAssertLessThan(timing.streamLatencyMilliseconds, 100)
    }
}

// MARK: - Session flow with virtual devices

@MainActor
final class StubBluetooth: BluetoothProviding {
    var connectCalls: [String] = []
    var disconnectCalls: [String] = []
    /// What `connect` reports; with `true` the link counts as up (like AirPods in the case).
    var linkComes = false
    var linkedAddresses: Set<String> = []
    var onLinkChange: (() -> Void)?
    func pairedHeadphones() -> [BluetoothHeadphone] {
        [BluetoothHeadphone(address: "AA-BB-CC-DD-EE-01", name: "AirPods Test A"),
         BluetoothHeadphone(address: "AA-BB-CC-DD-EE-02", name: "AirPods Test B")]
    }
    func connect(address: String, timeout: TimeInterval) async -> Bool {
        connectCalls.append(address)
        if linkComes { linkedAddresses.insert(address) }
        return linkComes
    }
    func isConnected(address: String) -> Bool { linkedAddresses.contains(address) }
    func disconnect(address: String, timeout: TimeInterval) async -> Bool {
        disconnectCalls.append(address)
        linkedAddresses.remove(address)
        return true
    }
    func isClosing(address: String) -> Bool { false }
    func batteryLevels() async -> [String: BatteryLevel] {
        Dictionary(uniqueKeysWithValues: linkedAddresses.map { (BluetoothAddress.normalized($0), BatteryLevel(left: 80, right: 75, chargingCase: 40)) })
    }
}

/// Holds connect calls open until the test releases them.
@MainActor
final class SuspendingBluetooth: BluetoothProviding {
    private var held: [CheckedContinuation<Bool, Never>] = []
    /// Hold every call, not only the first one.
    var holdsAll = false
    var connectCalls: [String] = []
    var disconnectCalls: [String] = []
    private var heldAddresses: [String] = []
    /// Links that came up when the held calls were released.
    private(set) var linked: Set<String> = []
    var onLinkChange: (() -> Void)?
    func pairedHeadphones() -> [BluetoothHeadphone] { StubBluetooth().pairedHeadphones() }
    func connect(address: String, timeout: TimeInterval) async -> Bool {
        connectCalls.append(address)
        return await withCheckedContinuation { continuation in
            if held.isEmpty || holdsAll {
                held.append(continuation)
                heldAddresses.append(address)
            } else {
                continuation.resume(returning: false)
            }
        }
    }
    func isConnected(address: String) -> Bool { linked.contains(address) }
    func disconnect(address: String, timeout: TimeInterval) async -> Bool {
        disconnectCalls.append(address)
        linked.remove(address)
        return true
    }
    func isClosing(address: String) -> Bool { false }
    func batteryLevels() async -> [String: BatteryLevel] { [:] }
    /// The held connections succeed, like a slow native connection that finishes after all.
    func release() {
        linked.formUnion(heldAddresses)
        held.forEach { $0.resume(returning: true) }
        held = []
        heldAddresses = []
        onLinkChange?()
    }
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
        XCTAssertEqual(controller.phase, .failed(L("Please choose different outputs.")))
    }

    func testNeedsAtLeastTwoChosenOutputs() async {
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        controller.select(nil, slot: 1)
        XCTAssertFalse(controller.canStart)
        await controller.start()
        XCTAssertEqual(controller.phase, .failed(L("Please choose at least two outputs.")))
        // An empty extra slot does not block a start.
        controller.select(OutputTarget(name: "BlackHole", deviceUID: VirtualDevices.first), slot: 1)
        controller.addOutput(OutputTarget(name: "Spare", deviceUID: "spare"))
        controller.select(nil, slot: 2)
        XCTAssertTrue(controller.canStart)
    }

    func testAddsAndRemovesOutputsAndKeepsThem() {
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        let speakers = OutputTarget(name: "Speakers", deviceUID: "BuiltInSpeakerDevice")
        XCTAssertTrue(controller.addableTargets.contains { $0.id == speakers.id })
        controller.addOutput(speakers)
        controller.addOutput(speakers) // already there
        XCTAssertEqual(controller.targets.count, 3)
        XCTAssertFalse(controller.addableTargets.contains { $0.id == speakers.id })
        XCTAssertEqual([controller.slotDevices.count, controller.volumes.count, controller.slotHasVolume.count,
                        controller.automaticDelays.count], [3, 3, 3, 3])
        XCTAssertEqual(controller.slotDevices[2]?.uid, "BuiltInSpeakerDevice")

        let relaunched = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        XCTAssertEqual(relaunched.targets.map { $0?.id }, controller.targets.map { $0?.id })

        controller.removeOutput(slot: 0)
        XCTAssertEqual(controller.targets.map { $0?.id }, ["bt:aabbccddee02", speakers.id])
        XCTAssertEqual(controller.slotDevices[1]?.uid, "BuiltInSpeakerDevice")
        controller.removeOutput(slot: 0) // two slots stay
        XCTAssertEqual(controller.targets.count, 2)
        XCTAssertEqual(controller.slotDevices.count, 2)
    }

    func testLoadsTwoSlotSettingsOfVersion12() throws {
        let saved: [OutputTarget?] = [OutputTarget(name: "A", deviceUID: "a"), nil]
        defaults.set(try JSONEncoder().encode(saved), forKey: "targets")
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        XCTAssertEqual(controller.targets.map { $0?.name }, ["A", nil])
    }

    func testManyBluetoothHeadphonesShowAHint() {
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        XCTAssertFalse(controller.hasManyBluetoothOutputs)
        controller.addOutput(OutputTarget(name: "AirPods C", bluetoothAddress: "AA-BB-CC-DD-EE-03"))
        XCTAssertTrue(controller.hasManyBluetoothOutputs)
    }

    func testDelayIsSavedPerDevice() {
        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        controller.setSyncOffset(42, slot: 1)
        XCTAssertEqual(controller.syncOffset(slot: 1), 40)
        XCTAssertEqual(controller.syncOffset(slot: 0), 0)
        // The value belongs to the device, not to the slot.
        let device = controller.targets[1]
        controller.select(nil, slot: 1)
        controller.select(device, slot: 0)
        XCTAssertEqual(controller.syncOffset(slot: 0), 40)
        let relaunched = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        XCTAssertEqual(relaunched.syncOffset(slot: 0), 40)
        controller.setSyncOffset(0, slot: 0)
        XCTAssertTrue(controller.syncOffsets.isEmpty)
    }

    func testFailsCleanlyWhenOneOfThreeDoesNotConnect() async throws {
        let (a, _) = try VirtualDevices.require()
        let bluetooth = StubBluetooth()
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.connectTimeout = 0.1
        controller.select(OutputTarget(name: a.name, deviceUID: a.uid), slot: 0)
        controller.select(OutputTarget(name: "Speakers", deviceUID: "BuiltInSpeakerDevice"), slot: 1)
        controller.addOutput(OutputTarget(name: "AirPods Test C", bluetoothAddress: "AA-BB-CC-DD-EE-03"))
        let outputBefore = AudioSystem.defaultOutputDeviceID()
        await controller.start()
        guard case .failed(let message) = controller.phase else { return XCTFail("expected failure, got \(controller.phase)") }
        XCTAssertTrue(message.contains("AirPods Test C"), message)
        XCTAssertFalse(message.contains(a.name), message)
        XCTAssertEqual(bluetooth.connectCalls, ["AA-BB-CC-DD-EE-03"])
        XCTAssertNil(AudioSystem.device(uid: testUID))
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), outputBefore)
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
        let outputBefore = try XCTUnwrap(AudioSystem.defaultOutputDeviceID())
        let volumesBefore = [Volume.get(a.id), Volume.get(b.id)]
        defer {
            if AudioSystem.defaultOutputDeviceID() != outputBefore { try? AudioSystem.setDefaultOutputDevice(outputBefore) }
            if let v = volumesBefore[0] { try? Volume.set(v, on: a.id) }
            if let v = volumesBefore[1] { try? Volume.set(v, on: b.id) }
            try? HAL.setValue(b.id, speakerMute, speakerMuteBefore, operation: "restore speaker mute")
        }
        try HAL.setValue(b.id, speakerMute, UInt32(1), operation: "mute speakers")

        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        controller.select(OutputTarget(name: a.name, deviceUID: a.uid), slot: 0)
        controller.select(OutputTarget(name: b.name, deviceUID: b.uid), slot: 1)
        await controller.start()
        XCTAssertEqual(controller.phase, .active)
        let aggregate = try XCTUnwrap(AudioSystem.device(uid: testUID))
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), aggregate.id)
        XCTAssertTrue(controller.isSelectedAsOutput)
        // BlackHole waits for the speakers' signal processing (stream latency); macOS aligns the rest itself.
        let speakerStream = OutputTiming.read(b.id).streamLatencyMilliseconds
        XCTAssertEqual(controller.automaticDelays[0], speakerStream, accuracy: 0.01)
        XCTAssertEqual(controller.automaticDelays[1], 0)
        // The menu explains it: the speakers are the output the others wait for, because of their own processing.
        XCTAssertEqual(controller.processingDelays[1], speakerStream, accuracy: 0.01)
        XCTAssertEqual(controller.processingDelays[0], 0, accuracy: 0.01)
        XCTAssertEqual(controller.timingReferenceSlot, speakerStream >= 0.5 ? 1 : nil)
        XCTAssertEqual(MultiOutputDevice.extraLatencyFrames(aggregate.id)[a.uid],
                       SyncDelays.frames(milliseconds: speakerStream, sampleRate: OutputTiming.read(a.id).sampleRate))

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

        // An output that comes back while muted stays silent and gets its own level back on unmute
        XCTAssertTrue(controller.handleMediaKey(mute))
        try Volume.set(0.6, on: b.id)
        controller.select(original, slot: 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(try XCTUnwrap(Volume.get(b.id)), 0, accuracy: 0.01)
        XCTAssertTrue(controller.handleMediaKey(mute))
        XCTAssertEqual(try XCTUnwrap(Volume.get(b.id)), 0.6, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(Volume.get(a.id)), levelA, accuracy: 0.02)
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

    /// A third output that can be the system output and can be muted (e.g. a USB DAC), muted for the test.
    private func silentThirdOutput(excluding: Set<String>) -> AudioDevice? {
        let mute = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        return AudioSystem.outputDevices().first { device in
            !excluding.contains(device.uid) && device.canBeDefaultOutput
                && BluetoothAddress.fromDeviceUID(device.uid) == nil && HAL.isSettable(device.id, mute)
        }
    }

    /// Three outputs: BlackHole, the built-in speakers and a third wired output, both muted meanwhile.
    func testThreeOutputsShareVolumeKeysAndTiming() async throws {
        let (a, _) = try VirtualDevices.require()
        let b = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
        guard let c = silentThirdOutput(excluding: [a.uid, b.uid, VirtualDevices.second]) else {
            throw XCTSkip("needs a third output with a mute control, e.g. a USB DAC")
        }
        let devices = [a, b, c]
        let mute = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        let muteBefore = try [b, c].map { try XCTUnwrap(HAL.value($0.id, mute, initial: UInt32(0)), $0.name) }
        let outputBefore = try XCTUnwrap(AudioSystem.defaultOutputDeviceID())
        let volumesBefore = devices.map { Volume.get($0.id) }
        // Cleanup first, so a failing step below cannot leave the speakers muted.
        defer {
            if AudioSystem.defaultOutputDeviceID() != outputBefore { try? AudioSystem.setDefaultOutputDevice(outputBefore) }
            for (device, volume) in zip(devices, volumesBefore) { if let volume { try? Volume.set(volume, on: device.id) } }
            for (device, value) in zip([b, c], muteBefore) { try? HAL.setValue(device.id, mute, value, operation: "restore mute") }
        }
        for device in [b, c] { try HAL.setValue(device.id, mute, UInt32(1), operation: "mute") }

        let controller = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        controller.select(OutputTarget(name: a.name, deviceUID: a.uid), slot: 0)
        controller.select(OutputTarget(name: b.name, deviceUID: b.uid), slot: 1)
        controller.addOutput(OutputTarget(name: c.name, deviceUID: c.uid))
        await controller.start()
        XCTAssertEqual(controller.phase, .active)
        let aggregate = try XCTUnwrap(AudioSystem.device(uid: testUID))
        XCTAssertEqual(Set(MultiOutputDevice.subDeviceUIDs(aggregate.id)), Set(devices.map(\.uid)))
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), aggregate.id)
        XCTAssertEqual(controller.chosenSlots, [0, 1, 2])

        // Every output that has a volume control moves by the same step.
        let controllable = controller.chosenSlots.filter { controller.slotHasVolume[$0] }
        for slot in controllable { controller.setVolume(0.5, slot: slot) }
        XCTAssertTrue(controller.handleMediaKey(MediaKeyEvent(key: .volumeUp, isDown: true, isRepeat: false, isFine: false)))
        for slot in controllable {
            XCTAssertEqual(try XCTUnwrap(Volume.get(devices[slot].id)), 0.5 + 1 / 16, accuracy: 0.02, devices[slot].name)
        }
        controller.linked = true
        controller.setVolume(0.3, slot: 0)
        for slot in controllable { XCTAssertEqual(controller.volumes[slot], 0.3, accuracy: 0.02) }
        controller.linked = false

        // A delay for one output takes effect on the running device, without rebuilding it.
        controller.setSyncOffset(120, slot: 2)
        try await Task.sleep(nanoseconds: 700_000_000)
        let expected = SyncDelays.frames(milliseconds: 120 + controller.automaticDelays[2],
                                         sampleRate: OutputTiming.read(c.id).sampleRate)
        XCTAssertEqual(MultiOutputDevice.extraLatencyFrames(aggregate.id)[c.uid], expected)
        XCTAssertEqual(AudioSystem.device(uid: testUID)?.id, aggregate.id)
        XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), aggregate.id)
        XCTAssertEqual(controller.phase, .active)

        // Relaunch adopts a session of three.
        let relaunched = SessionController(defaults: defaults, bluetooth: StubBluetooth(), multiOutputUID: testUID)
        relaunched.recoverOnLaunch()
        XCTAssertEqual(relaunched.phase, .active)

        controller.stop()
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

    // MARK: Connecting without a session

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testOpeningTheMenuConnectsTheChosenPairsAndReportsUnreachableOnes() async {
        let bluetooth = StubBluetooth()
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.unlinkedGrace = 0.1
        XCTAssertEqual(controller.slotStatus, [.notConnected, .notConnected])
        controller.menuOpened()
        XCTAssertEqual(controller.slotStatus, [.connecting, .connecting])
        await waitUntil { !controller.slotStatus.contains(.connecting) }
        XCTAssertEqual(controller.slotStatus, [.unreachable, .unreachable])
        XCTAssertEqual(Set(bluetooth.connectCalls), ["AA-BB-CC-DD-EE-01", "AA-BB-CC-DD-EE-02"])
        XCTAssertEqual(controller.phase, .idle)
    }

    func testLinkWithoutSoundCountsAsInTheCaseWithBattery() async {
        let bluetooth = StubBluetooth()
        bluetooth.linkComes = true
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.audioAppearTimeout = 0.1
        controller.menuOpened()
        await waitUntil { controller.slotStatus == [.inCase, .inCase] && !controller.slotBattery.contains(nil) }
        XCTAssertEqual(controller.slotStatus, [.inCase, .inCase])
        XCTAssertEqual(controller.slotBattery[0]?.lowest, 75)
    }

    func testPreconnectCanBeSwitchedOff() async throws {
        let bluetooth = StubBluetooth()
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.preconnectEnabled = false
        controller.menuOpened()
        controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(bluetooth.connectCalls, [])
        // The choice survives a relaunch.
        XCTAssertFalse(SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID).preconnectEnabled)
    }

    func testStartJoinsTheRunningPreconnectInsteadOfConnectingTwice() async throws {
        let bluetooth = SuspendingBluetooth()
        bluetooth.holdsAll = true
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.audioAppearTimeout = 0.1
        controller.menuOpened()
        await waitUntil { bluetooth.connectCalls.count == 2 }
        XCTAssertEqual(bluetooth.connectCalls.count, 2)
        let start = Task { await controller.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(controller.isWorking)
        XCTAssertEqual(bluetooth.connectCalls.count, 2)
        bluetooth.release()
        await start.value
        guard case .failed = controller.phase else { return XCTFail("expected failure, got \(controller.phase)") }
        XCTAssertEqual(bluetooth.connectCalls.count, 2)
        XCTAssertNil(AudioSystem.device(uid: testUID))
    }

    func testStopCancelsAPreconnect() async throws {
        let bluetooth = SuspendingBluetooth()
        bluetooth.holdsAll = true
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.menuOpened()
        XCTAssertEqual(controller.slotStatus, [.connecting, .connecting])
        controller.stop()
        XCTAssertEqual(controller.slotStatus, [.notConnected, .notConnected])
        bluetooth.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.slotStatus, [.notConnected, .notConnected])
    }

    // MARK: During and after a session

    /// A real session on BlackHole and the muted built-in speakers; everything is restored afterwards.
    private func withVirtualSession(_ bluetooth: BluetoothProviding, prepare: (SessionController) -> Void = { _ in },
                                    _ body: (SessionController) async throws -> Void) async throws {
        let (a, _) = try VirtualDevices.require()
        let b = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
        let speakerMute = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        let speakerMuteBefore = try XCTUnwrap(HAL.value(b.id, speakerMute, initial: UInt32(0)))
        try HAL.setValue(b.id, speakerMute, UInt32(1), operation: "mute speakers")
        let outputBefore = try XCTUnwrap(AudioSystem.defaultOutputDeviceID())
        let volumesBefore = [Volume.get(a.id), Volume.get(b.id)]
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        defer {
            controller.stop()
            if AudioSystem.defaultOutputDeviceID() != outputBefore { try? AudioSystem.setDefaultOutputDevice(outputBefore) }
            if let v = volumesBefore[0] { try? Volume.set(v, on: a.id) }
            if let v = volumesBefore[1] { try? Volume.set(v, on: b.id) }
            try? HAL.setValue(b.id, speakerMute, speakerMuteBefore, operation: "restore speaker mute")
        }
        controller.select(OutputTarget(name: a.name, deviceUID: a.uid), slot: 0)
        controller.select(OutputTarget(name: b.name, deviceUID: b.uid), slot: 1)
        prepare(controller)
        await controller.start()
        XCTAssertEqual(controller.phase, .active)
        try await body(controller)
    }

    func testDroppedPairIsFetchedBackAutomaticallyWithinItsBudget() async throws {
        let bluetooth = StubBluetooth()
        try await withVirtualSession(bluetooth, prepare: {
            $0.unlinkedGrace = 0.05
            $0.reconnectDelays = [0.05, 0.05, 0.05]
        }) { controller in
            let aggregate = try XCTUnwrap(AudioSystem.device(uid: testUID))
            // Slot 2 becomes a pair that cannot be reached, then drops out.
            controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 1)
            await controller.start() // fresh budget: a manual reconnect, which fails and only shows a notice
            controller.dismissMessage()
            bluetooth.connectCalls = []
            controller.pairLost(1)
            XCTAssertEqual(controller.slotStatus[1], .reconnecting(attempt: 1, of: 3))
            await waitUntil { controller.message != nil }
            XCTAssertEqual(bluetooth.connectCalls, Array(repeating: "AA-BB-CC-DD-EE-02", count: 3))
            XCTAssertEqual(controller.phase, .active)
            XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), aggregate.id)
            XCTAssertTrue(controller.message?.contains("AirPods Test B") == true, controller.message ?? "")
            XCTAssertEqual(controller.slotStatus[1], .unreachable)
            // Budget used up: another drop-out right away does not try again.
            controller.pairLost(1)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(bluetooth.connectCalls.count, 3)
        }
    }

    func testStopEndsAutomaticReconnecting() async throws {
        let bluetooth = StubBluetooth()
        try await withVirtualSession(bluetooth) { controller in
            controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 1)
            controller.pairLost(1)
            XCTAssertEqual(controller.slotStatus[1], .reconnecting(attempt: 1, of: 3))
            controller.stop()
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(bluetooth.connectCalls, [])
            XCTAssertEqual(controller.phase, .idle)
        }
    }

    func testStopReleasesTheGuestPairOnlyAfterASessionAndWhenWanted() async throws {
        let bluetooth = StubBluetooth()
        try await withVirtualSession(bluetooth) { controller in
            // The guest pair: Bluetooth, link up, after the owner's pair (the first Bluetooth pair).
            bluetooth.linkedAddresses = ["AA-BB-CC-DD-EE-02"]
            controller.select(OutputTarget(name: "AirPods Test A", bluetoothAddress: "AA-BB-CC-DD-EE-01"), slot: 0)
            controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 1)
            await controller.prepareForQuit()
            XCTAssertEqual(bluetooth.disconnectCalls, ["AA-BB-CC-DD-EE-02"])
            XCTAssertEqual(controller.phase, .idle)
            // Opening the menu afterwards does not pull the released pair back.
            bluetooth.connectCalls = []
            controller.menuOpened()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(bluetooth.connectCalls.contains("AA-BB-CC-DD-EE-02"))

            // No session: nothing to release.
            bluetooth.linkedAddresses = ["AA-BB-CC-DD-EE-02"]
            await controller.prepareForQuit()
            XCTAssertEqual(bluetooth.disconnectCalls.count, 1)
        }
        // Option off.
        let keep = StubBluetooth()
        try await withVirtualSession(keep) { controller in
            controller.releaseGuestOnStop = false
            keep.linkedAddresses = ["AA-BB-CC-DD-EE-02"]
            controller.select(OutputTarget(name: "AirPods Test A", bluetoothAddress: "AA-BB-CC-DD-EE-01"), slot: 0)
            controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 1)
            await controller.prepareForQuit()
            XCTAssertEqual(keep.disconnectCalls, [])
            controller.releaseGuestOnStop = true
        }
    }

    func testGuestPairThatLinksUpOnlyAfterStopIsReleasedToo() async throws {
        let bluetooth = SuspendingBluetooth()
        bluetooth.holdsAll = true
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.preconnectEnabled = false
        controller.audioAppearTimeout = 0.1
        let start = Task { await controller.start() }
        await waitUntil { bluetooth.connectCalls.count == 2 }
        controller.stop()
        bluetooth.release() // the native connections finish after Stop
        await start.value
        await waitUntil { !bluetooth.disconnectCalls.isEmpty }
        XCTAssertEqual(bluetooth.disconnectCalls, ["AA-BB-CC-DD-EE-02"])
        XCTAssertEqual(controller.phase, .idle)
    }

    func testChoosingTheGuestPairAgainKeepsItsLateConnection() async throws {
        let bluetooth = SuspendingBluetooth()
        bluetooth.holdsAll = true
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.preconnectEnabled = false
        controller.audioAppearTimeout = 0.1
        let start = Task { await controller.start() }
        await waitUntil { bluetooth.connectCalls.count == 2 }
        controller.stop()
        controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 1)
        bluetooth.release()
        await start.value
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(bluetooth.disconnectCalls, [])
    }

    // MARK: More than two outputs

    func testStatusAndBatteryCoverEveryOutput() async {
        let bluetooth = StubBluetooth()
        bluetooth.linkComes = true
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.audioAppearTimeout = 0.1
        // An added pair is connected right away, like a chosen one.
        controller.addOutput(OutputTarget(name: "AirPods Test C", bluetoothAddress: "AA-BB-CC-DD-EE-03"))
        XCTAssertEqual(controller.slotStatus[2], .connecting)
        controller.menuOpened()
        await waitUntil { controller.slotStatus == [.inCase, .inCase, .inCase] && !controller.slotBattery.contains(nil) }
        XCTAssertEqual(controller.slotStatus, [.inCase, .inCase, .inCase])
        XCTAssertEqual(controller.slotBattery[2]?.lowest, 75)
        XCTAssertEqual(Set(bluetooth.connectCalls), ["AA-BB-CC-DD-EE-01", "AA-BB-CC-DD-EE-02", "AA-BB-CC-DD-EE-03"])

        controller.addOutput(OutputTarget(name: "Speakers", deviceUID: "BuiltInSpeakerDevice"))
        XCTAssertEqual(controller.slotStatus[3], .connected)
        XCTAssertNil(controller.slotBattery[3])
        controller.removeOutput(slot: 0)
        XCTAssertEqual(controller.slotStatus, [.inCase, .inCase, .connected])
        XCTAssertEqual(controller.slotBattery.map { $0 != nil }, [true, true, false])
    }

    func testEveryBluetoothPairAfterTheFirstIsReleasedAsAGuest() async throws {
        let bluetooth = StubBluetooth()
        try await withVirtualSession(bluetooth, prepare: { controller in
            // Two empty extra slots, filled with pairs while the session runs.
            controller.addOutput(OutputTarget(name: "Spare 1", deviceUID: "spare-1"))
            controller.addOutput(OutputTarget(name: "Spare 2", deviceUID: "spare-2"))
            controller.select(nil, slot: 2)
            controller.select(nil, slot: 3)
        }) { controller in
            bluetooth.linkedAddresses = ["AA-BB-CC-DD-EE-01", "AA-BB-CC-DD-EE-02", "AA-BB-CC-DD-EE-03"]
            // A wired output first: the owner's pair is the first Bluetooth pair, wherever it is.
            controller.select(OutputTarget(name: "AirPods Test A", bluetoothAddress: "AA-BB-CC-DD-EE-01"), slot: 1)
            controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 2)
            controller.select(OutputTarget(name: "AirPods Test C", bluetoothAddress: "AA-BB-CC-DD-EE-03"), slot: 3)
            XCTAssertEqual(controller.slotStatus.count, 4)
            await controller.prepareForQuit()
            XCTAssertEqual(Set(bluetooth.disconnectCalls), ["AA-BB-CC-DD-EE-02", "AA-BB-CC-DD-EE-03"])
            XCTAssertEqual(bluetooth.disconnectCalls.count, 2)
            // Opening the menu afterwards pulls neither guest back.
            bluetooth.connectCalls = []
            controller.menuOpened()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(bluetooth.connectCalls.contains("AA-BB-CC-DD-EE-02"))
            XCTAssertFalse(bluetooth.connectCalls.contains("AA-BB-CC-DD-EE-03"))
        }
    }

    func testAThirdPairIsFetchedBackAutomaticallyToo() async throws {
        let bluetooth = StubBluetooth()
        try await withVirtualSession(bluetooth, prepare: {
            $0.unlinkedGrace = 0.05
            $0.reconnectDelays = [0.05, 0.05, 0.05]
            $0.addOutput(OutputTarget(name: "Spare", deviceUID: "spare"))
            $0.select(nil, slot: 2)
        }) { controller in
            let aggregate = try XCTUnwrap(AudioSystem.device(uid: testUID))
            controller.select(OutputTarget(name: "AirPods Test C", bluetoothAddress: "AA-BB-CC-DD-EE-03"), slot: 2)
            controller.pairLost(2)
            XCTAssertEqual(controller.slotStatus[2], .reconnecting(attempt: 1, of: 3))
            XCTAssertEqual(controller.slotStatus[0], .connected)
            await waitUntil { controller.message != nil }
            XCTAssertEqual(bluetooth.connectCalls, Array(repeating: "AA-BB-CC-DD-EE-03", count: 3))
            XCTAssertTrue(controller.message?.contains("AirPods Test C") == true, controller.message ?? "")
            XCTAssertEqual(controller.slotStatus[2], .unreachable)
            // The two outputs that kept playing are untouched.
            XCTAssertEqual(controller.phase, .active)
            XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), aggregate.id)
            XCTAssertEqual(AudioSystem.device(uid: testUID)?.id, aggregate.id)
        }
    }

    // MARK: Edge cases of reconnecting and releasing

    func testAReturningOutputPlaysAgainWhileAnotherIsStillMissing() async throws {
        let bluetooth = StubBluetooth()
        try await withVirtualSession(bluetooth, prepare: {
            $0.addOutput(OutputTarget(name: "Spare", deviceUID: "spare"))
            $0.select(nil, slot: 2)
        }) { controller in
            let (a, _) = try VirtualDevices.require()
            let speakers = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
            controller.setSyncOffset(40, slot: 1)
            // A third pair that is not back yet.
            controller.select(OutputTarget(name: "AirPods Test C", bluetoothAddress: "AA-BB-CC-DD-EE-03"), slot: 2)
            // BlackHole leaves the shared output and Core Audio does not take it back by itself.
            let before = try XCTUnwrap(AudioSystem.device(uid: testUID))
            try HAL.setValue(before.id, propertyAddress(kAudioAggregateDevicePropertyFullSubDeviceList),
                             [speakers.uid] as CFArray, operation: "drop BlackHole")
            await waitUntil { MultiOutputDevice.activeSubDeviceUIDs(before.id) == [speakers.uid] }
            controller.select(nil, slot: 0)
            controller.select(OutputTarget(name: a.name, deviceUID: a.uid), slot: 0) // BlackHole is back

            await waitUntil {
                AudioSystem.device(uid: testUID).map { Set(MultiOutputDevice.activeSubDeviceUIDs($0.id)) } == [a.uid, speakers.uid]
                    && AudioSystem.defaultOutputDeviceID() == AudioSystem.device(uid: testUID)?.id
            }
            let aggregate = try XCTUnwrap(AudioSystem.device(uid: testUID))
            XCTAssertEqual(Set(MultiOutputDevice.activeSubDeviceUIDs(aggregate.id)), [a.uid, speakers.uid])
            XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), aggregate.id)
            XCTAssertEqual(controller.phase, .active)
            // Each output keeps its delay in the rebuilt device.
            XCTAssertEqual(MultiOutputDevice.extraLatencyFrames(aggregate.id)[speakers.uid],
                           SyncDelays.frames(milliseconds: 40 + controller.automaticDelays[1],
                                             sampleRate: OutputTiming.read(speakers.id).sampleRate))
        }
    }

    func testOutputPickedWhileAPairIsFetchedBackIsKept() async throws {
        let bluetooth = SuspendingBluetooth()
        try await withVirtualSession(bluetooth, prepare: {
            $0.audioAppearTimeout = 0.1
            $0.reconnectDelays = [0.05] // one attempt
        }) { controller in
            let aggregate = try XCTUnwrap(AudioSystem.device(uid: testUID))
            let speakers = try XCTUnwrap(AudioSystem.device(uid: "BuiltInSpeakerDevice"))
            // The second output becomes a pair that drops out; the speakers stay in the shared output.
            controller.select(OutputTarget(name: "AirPods Test B", bluetoothAddress: "AA-BB-CC-DD-EE-02"), slot: 1)
            controller.pairLost(1)
            await waitUntil { bluetooth.connectCalls.count == 1 }
            XCTAssertTrue(controller.isReconnecting)
            // While Zweiklang waits for the pair, the user picks the speakers alone.
            try AudioSystem.setDefaultOutputDevice(speakers.id)
            try await Task.sleep(nanoseconds: 300_000_000)
            bluetooth.release() // linked, but no sound device: the pair stays missing
            await waitUntil { controller.message != nil }
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(AudioSystem.defaultOutputDeviceID(), speakers.id)
            XCTAssertFalse(controller.isSelectedAsOutput)
            XCTAssertEqual(controller.phase, .active)
            XCTAssertEqual(AudioSystem.device(uid: testUID)?.id, aggregate.id)
        }
    }

    func testQuitWaitsForAGuestPairThatIsStillConnecting() async throws {
        let bluetooth = SuspendingBluetooth()
        bluetooth.holdsAll = true
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.preconnectEnabled = false
        controller.audioAppearTimeout = 0.1
        let start = Task { await controller.start() }
        await waitUntil { bluetooth.connectCalls.count == 2 }
        let quit = Task { () -> Date in
            await controller.prepareForQuit()
            return Date()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let linksCameUp = Date()
        bluetooth.release() // the native connections finish while the app quits
        let quitEnded = await quit.value
        XCTAssertGreaterThan(quitEnded, linksCameUp)
        XCTAssertEqual(bluetooth.disconnectCalls, ["AA-BB-CC-DD-EE-02"])
        await start.value
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAPairTakenOutOfTheListIsNotLeftConnected() async throws {
        let bluetooth = SuspendingBluetooth()
        bluetooth.holdsAll = true
        let controller = SessionController(defaults: defaults, bluetooth: bluetooth, multiOutputUID: testUID)
        controller.audioAppearTimeout = 0.1
        let carla = OutputTarget(name: "AirPods Test C", bluetoothAddress: "AA-BB-CC-DD-EE-03")
        controller.addOutput(carla) // connects in the background
        await waitUntil { bluetooth.connectCalls.count == 1 }
        controller.removeOutput(slot: 2)
        bluetooth.release() // the connection comes up after all
        await waitUntil { !bluetooth.disconnectCalls.isEmpty }
        XCTAssertEqual(bluetooth.disconnectCalls, ["AA-BB-CC-DD-EE-03"])

        // The same when another output replaces it.
        controller.addOutput(carla)
        await waitUntil { bluetooth.connectCalls.count == 2 }
        controller.select(OutputTarget(name: "Speakers", deviceUID: "BuiltInSpeakerDevice"), slot: 2)
        bluetooth.release()
        await waitUntil { bluetooth.disconnectCalls.count == 2 }
        XCTAssertEqual(bluetooth.disconnectCalls, ["AA-BB-CC-DD-EE-03", "AA-BB-CC-DD-EE-03"])
        XCTAssertEqual(bluetooth.connectCalls, ["AA-BB-CC-DD-EE-03", "AA-BB-CC-DD-EE-03"])
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
