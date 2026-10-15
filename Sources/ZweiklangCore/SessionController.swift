import CoreAudio
import Foundation
import Observation
import os

let log = Logger(subsystem: "ch.moritz.zweiklang", category: "session")

/// A pair of headphones (or any output) the user picked for one of the two slots.
public struct OutputTarget: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    /// Set for Bluetooth headphones; the app can connect those itself.
    public var bluetoothAddress: String?
    /// Set for other outputs (USB, built-in, virtual).
    public var deviceUID: String?

    public init(name: String, bluetoothAddress: String? = nil, deviceUID: String? = nil) {
        self.name = name
        self.bluetoothAddress = bluetoothAddress
        self.deviceUID = deviceUID
    }

    public var id: String {
        if let bluetoothAddress { return "bt:" + BluetoothAddress.normalized(bluetoothAddress) }
        return "uid:" + (deviceUID ?? name)
    }

    public func matches(_ device: AudioDevice) -> Bool {
        guard device.hasOutput, !device.isAggregate else { return false }
        if let bluetoothAddress { return BluetoothAddress.matches(deviceUID: device.uid, address: bluetoothAddress) }
        return device.uid == deviceUID
    }
}

public enum SessionPhase: Equatable, Sendable {
    case idle
    case working(String)
    case active
    case failed(String)
}

/// Connects both headphones, builds the multi-output device, makes it the system output
/// and controls the two volumes.
@MainActor
@Observable
public final class SessionController {
    public static let slotCount = 2

    public private(set) var phase: SessionPhase = .idle {
        didSet {
            if (oldValue == .active) != (phase == .active) { onActiveChange?(phase == .active) }
        }
    }
    public private(set) var targets: [OutputTarget?] = [nil, nil]
    public private(set) var candidates: [OutputTarget] = []
    /// Audio device of each slot, nil while it is not connected.
    public private(set) var slotDevices: [AudioDevice?] = [nil, nil]
    public private(set) var volumes: [Float] = [0.5, 0.5]
    public private(set) var isMuted = false
    /// True while the multi-output device is the system output.
    public private(set) var isSelectedAsOutput = false
    /// Whether each slot's device lets us set its volume.
    public private(set) var slotHasVolume: [Bool] = [false, false]
    /// Notice during a running session, e.g. a failed reconnect.
    public private(set) var message: String?
    public var linked = false {
        didSet { defaults.set(linked, forKey: Keys.linked) }
    }

    /// Called after a volume key changed the volume (for the on-screen display).
    @ObservationIgnored public var onVolumeKeyFeedback: (() -> Void)?
    /// Called when a session becomes active or ends (the volume-key tap only runs meanwhile).
    @ObservationIgnored public var onActiveChange: ((Bool) -> Void)?
    @ObservationIgnored public var connectTimeout: TimeInterval = 12
    @ObservationIgnored public var audioAppearTimeout: TimeInterval = 15
    /// Fixed names for screenshots.
    @ObservationIgnored var displayNameOverrides: [Int: String] = [:]

    public let multiOutputUID: String
    private let defaults: UserDefaults
    private let bluetooth: BluetoothProviding
    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var volumeListeners: [PropertyListener] = []
    @ObservationIgnored private var observedDeviceIDs: [AudioObjectID] = []
    @ObservationIgnored private var volumesBeforeMute: [Float]?
    /// A start runs (also while it winds down after "Cancel").
    public private(set) var isBusy = false
    /// "Reconnect" during a running session; the session stays usable meanwhile.
    public private(set) var isReconnecting = false
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var volumeReadQueued = false

    private enum Keys {
        static let targets = "targets"
        static let linked = "linked"
        static let previousOutput = "previousOutputUID"
    }

    public init(defaults: UserDefaults, bluetooth: BluetoothProviding, multiOutputUID: String = MultiOutputDevice.defaultUID) {
        AudioSystem.configure()
        self.defaults = defaults
        self.bluetooth = bluetooth
        self.multiOutputUID = multiOutputUID
        self.linked = defaults.bool(forKey: Keys.linked)
        if let data = defaults.data(forKey: Keys.targets),
           let saved = try? JSONDecoder().decode([OutputTarget?].self, from: data),
           saved.count == Self.slotCount {
            targets = saved
        }
        installSystemListeners()
        refresh()
        // First launch only: pre-select two AirPods. Later an empty choice stays empty.
        if defaults.data(forKey: Keys.targets) == nil {
            pickDefaultTargets()
            refresh()
        }
    }

    // MARK: - Selection

    public func displayName(slot: Int) -> String {
        displayNameOverrides[slot] ?? targets[slot]?.name ?? L("Headphones \(String(slot + 1))")
    }

    public func select(_ target: OutputTarget?, slot: Int) {
        targets[slot] = target
        saveTargets()
        if case .failed = phase { phase = .idle }
        refresh()
    }

    /// Re-reads devices, connection state, volumes and the current system output.
    public func refresh() {
        let outputs = AudioSystem.outputDevices()
        var list = bluetooth.pairedHeadphones().map { headphone in
            // Core Audio carries the name set in System Settings ("Anna’s AirPods Pro").
            let target = OutputTarget(name: headphone.name, bluetoothAddress: headphone.address)
            return OutputTarget(name: outputs.first(where: target.matches)?.name ?? headphone.name, bluetoothAddress: headphone.address)
        }
        for device in outputs where device.canBeDefaultOutput {
            let target: OutputTarget
            if let address = BluetoothAddress.fromDeviceUID(device.uid) {
                target = OutputTarget(name: device.name, bluetoothAddress: address)
            } else {
                target = OutputTarget(name: device.name, deviceUID: device.uid)
            }
            if !list.contains(where: { $0.id == target.id }) { list.append(target) }
        }
        for case let target? in targets where !list.contains(where: { $0.id == target.id }) {
            list.append(target)
        }
        candidates = list

        let devices = targets.map { target in target.flatMap { t in outputs.first(where: t.matches) } }
        if devices.map({ $0?.id }) != slotDevices.map({ $0?.id }) {
            slotHasVolume = devices.map { $0.map { Volume.canControl($0.id) } ?? false }
        }
        slotDevices = devices
        for (slot, device) in slotDevices.enumerated() {
            if let device, let target = targets[slot], target.name != device.name {
                targets[slot]?.name = device.name
                saveTargets()
            }
        }
        let aggregate = aggregateDevice()
        isSelectedAsOutput = aggregate != nil && aggregate?.id == AudioSystem.defaultOutputDeviceID()

        if phase == .active {
            // While a reconnect rebuilds the device it is briefly missing; that is not an end.
            if aggregate == nil, !isBusy {
                endMute()
                removeVolumeObservers()
                defaults.removeObject(forKey: Keys.previousOutput)
                phase = .failed(L("The shared output was removed."))
                return
            }
            syncVolumeObservers()
            readVolumes()
        }
    }

    private func pickDefaultTargets() {
        let bluetoothTargets = candidates.filter { $0.bluetoothAddress != nil }
        // Own AirPods (name contains the user's first name) first, the guest pair second.
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        let airPods = bluetoothTargets.filter { $0.name.localizedCaseInsensitiveContains("AirPods") }
            .sorted { $0.name.localizedCaseInsensitiveContains(firstName) && !$1.name.localizedCaseInsensitiveContains(firstName) }
        let picks = Array((airPods.count >= 2 ? airPods : bluetoothTargets).prefix(Self.slotCount))
        guard !picks.isEmpty else { return }
        for (slot, target) in picks.enumerated() { targets[slot] = target }
        saveTargets()
    }

    private func saveTargets() {
        if let data = try? JSONEncoder().encode(targets) { defaults.set(data, forKey: Keys.targets) }
    }

    // MARK: - Start / stop

    public var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    public var canStart: Bool { startProblem == nil }

    private var startProblem: String? {
        guard let first = targets[0], let second = targets[1] else { return L("Please choose two headphones.") }
        return first.id == second.id ? L("Please choose two different headphones.") : nil
    }

    /// Starts a session, or reconnects missing headphones while one runs.
    public func start() async {
        guard !isBusy else { return }
        if let startProblem {
            phase = .failed(startProblem)
            return
        }
        guard let first = targets[0], let second = targets[1] else { return }
        isBusy = true
        cancelRequested = false
        message = nil
        let wasActive = phase == .active
        isReconnecting = wasActive
        defer {
            isBusy = false
            isReconnecting = false
        }
        if !wasActive {
            // Remember the output before connecting: macOS may switch to freshly connected AirPods.
            rememberPreviousOutput()
            phase = .working(L("Connecting headphones …"))
        }

        log.info("start: \(first.name, privacy: .private(mask: .hash)) + \(second.name, privacy: .private(mask: .hash))")
        async let deviceA = ensureAvailable(first)
        async let deviceB = ensureAvailable(second)
        let devices = await [deviceA, deviceB]
        if cancelRequested { return } // stop() already cleaned up

        let missing = zip([first, second], devices).filter { $0.1 == nil }.map(\.0.name)
        guard missing.isEmpty, let a = devices[0], let b = devices[1] else {
            let reason = missing.count > 1
                ? L("“\(missing[0])” and “\(missing[1])” could not be connected. Take the AirPods out of the case, hold them near the Mac and try again.")
                : L("“\(missing[0])” could not be connected. Take the AirPods out of the case, hold them near the Mac and try again.")
            failStart(wasActive: wasActive, reason: reason)
            return
        }

        if !wasActive { phase = .working(L("Setting up the shared output …")) }
        do {
            let aggregate = try await prepareAggregate(subDeviceUIDs: [a.uid, b.uid])
            if cancelRequested { cleanUpSession(); return }
            try await switchOutput(to: aggregate)
            if cancelRequested { cleanUpSession(); return }
        } catch {
            if cancelRequested { cleanUpSession(); return } // stopped meanwhile: stay idle
            failStart(wasActive: wasActive, reason: error.localizedDescription)
            return
        }
        if !wasActive {
            isMuted = false
            volumesBeforeMute = nil
        }
        phase = .active
        refresh()
        log.info("active: \(a.uid, privacy: .private(mask: .hash)) + \(b.uid, privacy: .private(mask: .hash)), volumes \(self.volumes, privacy: .private(mask: .hash))")
    }

    /// A failed reconnect keeps a still-working session (with a notice); anything else is rolled back completely.
    private func failStart(wasActive: Bool, reason: String) {
        log.error("start failed: \(reason, privacy: .private(mask: .hash))")
        if wasActive, let aggregate = aggregateDevice(), AudioSystem.defaultOutputDeviceID() == aggregate.id {
            message = reason
            phase = .active
        } else {
            endMute()
            cleanUpSession()
            if !wasActive { rollbackOutput() }
            defaults.removeObject(forKey: Keys.previousOutput)
            phase = .failed(reason)
        }
        refresh()
    }

    /// Ends the session (or cancels a start in progress): brings back the previous output
    /// and removes the multi-output device. Safe to call in any state.
    public func stop() {
        let wasBusy = isBusy
        if wasBusy { cancelRequested = true }
        endMute()
        message = nil
        cleanUpSession()
        if wasBusy { rollbackOutput() }
        defaults.removeObject(forKey: Keys.previousOutput)
        phase = .idle
        refresh()
        log.info("stopped, output now \(AudioSystem.defaultOutputDeviceID().flatMap(AudioSystem.device(id:))?.name ?? "-", privacy: .private(mask: .hash))")
    }

    /// Gives the headphones their volume back if the session ends while muted.
    private func endMute() {
        if isMuted, let saved = volumesBeforeMute { setDeviceVolumes(saved) }
        isMuted = false
        volumesBeforeMute = nil
    }

    private func cleanUpSession() {
        removeVolumeObservers()
        restorePreviousOutput()
        if let aggregate = aggregateDevice() {
            do { try MultiOutputDevice.destroy(aggregate.id) } catch {
                log.error("destroy failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
            }
        }
    }

    /// Makes the multi-output device the system output again (if something else took over).
    public func selectAsOutput() {
        if let aggregate = aggregateDevice() { try? AudioSystem.setDefaultOutputDevice(aggregate.id) }
        refresh()
    }

    /// After a crash or relaunch: continue a still-running session or clean it up.
    public func recoverOnLaunch() {
        guard let aggregate = aggregateDevice() else {
            defaults.removeObject(forKey: Keys.previousOutput)
            return
        }
        let expected = slotDevices.compactMap { $0?.uid }
        let isOurs = expected.count == Self.slotCount
            && Set(MultiOutputDevice.subDeviceUIDs(aggregate.id)) == Set(expected)
        if isOurs && AudioSystem.defaultOutputDeviceID() == aggregate.id {
            phase = .active
            refresh()
        } else {
            stop()
        }
    }

    public func dismissMessage() {
        message = nil
        if case .failed = phase { phase = .idle }
    }

    private func aggregateDevice() -> AudioDevice? {
        MultiOutputDevice.find(uid: multiOutputUID)
    }

    private func currentDevice(for target: OutputTarget) -> AudioDevice? {
        AudioSystem.outputDevices().first(where: target.matches)
    }

    private func ensureAvailable(_ target: OutputTarget) async -> AudioDevice? {
        if let device = currentDevice(for: target) { return device }
        guard let address = target.bluetoothAddress else { return nil }
        let linked = await bluetooth.connect(address: address, timeout: connectTimeout)
        log.info("bluetooth connect \(target.name, privacy: .private(mask: .hash)): \(linked, privacy: .private(mask: .hash))")
        // macOS sometimes finishes the connection even when the call reports a failure.
        let deadline = Date().addingTimeInterval(linked ? audioAppearTimeout : 4)
        while Date() < deadline, !cancelRequested {
            if currentDevice(for: target) != nil {
                // Give the freshly published device a moment to settle before using it.
                try? await Task.sleep(nanoseconds: 700_000_000)
                return currentDevice(for: target)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if linked { log.error("\(target.name, privacy: .private(mask: .hash)) connected, but no audio device appeared (still in the case?)") }
        return nil
    }

    private func prepareAggregate(subDeviceUIDs: [String]) async throws -> AudioDevice {
        if let existing = aggregateDevice() {
            if existing.hasOutput, MultiOutputDevice.subDeviceUIDs(existing.id) == subDeviceUIDs { return existing }
            try MultiOutputDevice.destroy(existing.id)
        }
        return try await MultiOutputDevice.create(subDeviceUIDs: subDeviceUIDs, uid: multiOutputUID)
    }

    /// macOS can accept the switch without error and still keep the old output; check it really happened.
    /// On failure the caller removes the device.
    private func switchOutput(to aggregate: AudioDevice) async throws {
        try AudioSystem.setDefaultOutputDevice(aggregate.id)
        let deadline = Date().addingTimeInterval(1)
        while AudioSystem.defaultOutputDeviceID() != aggregate.id, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard AudioSystem.defaultOutputDeviceID() == aggregate.id else {
            throw AudioError(status: kAudioHardwareIllegalOperationError, operation: L("Selecting the audio output"))
        }
    }

    private func rememberPreviousOutput() {
        guard let id = AudioSystem.defaultOutputDeviceID(),
              let device = AudioSystem.device(id: id),
              device.uid != multiOutputUID else { return }
        defaults.set(device.uid, forKey: Keys.previousOutput)
    }

    private func previousOutput() -> AudioDevice? {
        guard let uid = defaults.string(forKey: Keys.previousOutput), uid != multiOutputUID,
              let device = AudioSystem.device(uid: uid), device.hasOutput else { return nil }
        return device
    }

    /// Only touches the output while the multi-output device still owns it. Waits until macOS
    /// has switched, so removing the device afterwards cannot make macOS pick something else.
    private func restorePreviousOutput() {
        guard let aggregate = aggregateDevice(), AudioSystem.defaultOutputDeviceID() == aggregate.id else { return }
        // Prefer headphones over speakers if the old output is gone: no film sound in the room by surprise.
        guard let target = previousOutput() ?? slotDevices.compactMap({ $0 }).first else { return }
        do {
            try AudioSystem.setDefaultOutputDevice(target.id)
        } catch {
            log.error("restore output failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return
        }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, AudioSystem.defaultOutputDeviceID() == aggregate.id {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Undo an output switch macOS made while connecting, if the start failed.
    private func rollbackOutput() {
        guard let previous = previousOutput(), let current = AudioSystem.defaultOutputDeviceID(),
              current != previous.id else { return }
        let outputs = AudioSystem.outputDevices()
        let ownDevices = targets.compactMap { target in target.flatMap { t in outputs.first(where: t.matches)?.id } }
        if ownDevices.contains(current) { try? AudioSystem.setDefaultOutputDevice(previous.id) }
    }

    // MARK: - Volume

    public func setVolume(_ value: Float, slot: Int) {
        guard phase == .active else { return }
        let value = Self.clamp(value)
        var values = volumes
        if linked {
            let delta = value - volumes[slot]
            values = volumes.map { Self.clamp($0 + delta) }
        }
        values[slot] = value
        apply(values)
    }

    /// Volume keys: both headphones move by the same step, so their difference stays.
    public func changeAll(by delta: Float) {
        guard phase == .active else { return }
        var base = volumes
        if isMuted, let saved = volumesBeforeMute {
            base = saved
            isMuted = false
            volumesBeforeMute = nil
        }
        apply(base.map { Self.clamp($0 + delta) })
    }

    public func toggleMute() {
        guard phase == .active else { return }
        if isMuted {
            let saved = volumesBeforeMute ?? volumes
            isMuted = false
            volumesBeforeMute = nil
            apply(saved)
        } else {
            let before = volumes
            apply(volumes.map { _ in 0 })
            // Only claim "muted" if every connected device really went silent.
            let connected = slotDevices.indices.filter { slotDevices[$0] != nil }
            if !connected.isEmpty, connected.allSatisfy({ volumes[$0] < 0.01 }) {
                volumesBeforeMute = before
                isMuted = true
            }
        }
    }

    /// Volume keys while Zweiklang is the output. Returns true if the key was handled (and should be swallowed).
    public func handleMediaKey(_ event: MediaKeyEvent) -> Bool {
        guard phase == .active, isSelectedAsOutput else { return false }
        guard event.isDown else { return true }
        let step: Float = event.isFine ? 1 / 64 : 1 / 16
        switch event.key {
        case .volumeUp: changeAll(by: step)
        case .volumeDown: changeAll(by: -step)
        case .mute: if !event.isRepeat { toggleMute() }
        }
        onVolumeKeyFeedback?()
        return true
    }

    private func apply(_ values: [Float]) {
        if isMuted, values.contains(where: { $0 > 0 }) {
            isMuted = false
            volumesBeforeMute = nil
        }
        let succeeded = setDeviceVolumes(values)
        // Show what the device really has where setting failed (disconnected, no volume control).
        volumes = values.enumerated().map { slot, value in
            succeeded[slot] ? value : (slotDevices[slot].flatMap { Volume.get($0.id) } ?? volumes[slot])
        }
        log.debug("volumes \(self.volumes, privacy: .private(mask: .hash))")
    }

    @discardableResult
    private func setDeviceVolumes(_ values: [Float]) -> [Bool] {
        zip(slotDevices, values).map { device, value in
            guard let device else { return false }
            do {
                try Volume.set(value, on: device.id)
                return true
            } catch {
                log.error("volume \(device.name, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))")
                return false
            }
        }
    }

    private func readVolumes() {
        let current = slotDevices.map { $0.flatMap { Volume.get($0.id) } }
        if isMuted {
            // Someone turned it up elsewhere (AirPods stem, another app): no longer muted.
            guard current.contains(where: { ($0 ?? 0) > 0.015 }) else { return }
            isMuted = false
            volumesBeforeMute = nil
        }
        for (slot, value) in current.enumerated() {
            // Small differences come from the device rounding our own value; ignore them so sliders do not jump.
            if let value, abs(value - volumes[slot]) > 0.015 { volumes[slot] = value }
        }
    }

    static func clamp(_ value: Float) -> Float { min(max(value, 0), 1) }

    // MARK: - HAL listeners

    private func installSystemListeners() {
        let onChange: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        systemListeners = [
            PropertyListener(objectID: HAL.systemObject, address: propertyAddress(kAudioHardwarePropertyDevices), handler: onChange),
            PropertyListener(objectID: HAL.systemObject, address: propertyAddress(kAudioHardwarePropertyDefaultOutputDevice), handler: onChange),
        ].compactMap { $0 }
    }

    private func syncVolumeObservers() {
        let ids = slotDevices.compactMap { $0?.id }
        guard ids != observedDeviceIDs else { return }
        removeVolumeObservers()
        observedDeviceIDs = ids
        for id in ids {
            volumeListeners += Volume.observe(id) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleVolumeRead() }
            }
        }
    }

    /// HAL notifications come in bursts (device created, output switched, both volume properties);
    /// handle each burst once.
    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    private func scheduleVolumeRead() {
        guard !volumeReadQueued else { return }
        volumeReadQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.volumeReadQueued = false
                if self?.phase == .active { self?.readVolumes() }
            }
        }
    }

    private func removeVolumeObservers() {
        volumeListeners.forEach { $0.remove() }
        volumeListeners = []
        observedDeviceIDs = []
    }
}
