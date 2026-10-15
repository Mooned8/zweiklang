import CoreAudio
import Foundation
import Observation
import os

let log = Logger(subsystem: "ch.moritz.zweiklang", category: "session")

/// Headphones (or any other output) the user picked for one of the slots.
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

/// What the menu shows below each output.
public enum PairStatus: Equatable, Sendable {
    case none
    /// The sound device is there.
    case connected
    case connecting
    /// Automatic attempt during a session.
    case reconnecting(attempt: Int, of: Int)
    /// Bluetooth link without a sound device, which is what AirPods in the closed charging case do.
    case inCase
    /// The last attempt failed: switched off, too far away or playing on another device.
    case unreachable
    case notConnected
    /// A wired or virtual output that is missing.
    case unavailable
}

/// Connects the chosen outputs, builds the multi-output device, makes it the system output
/// and controls each output's volume and timing.
@MainActor
@Observable
public final class SessionController {
    /// The menu always shows at least this many slots, and a session needs this many outputs.
    public static let minimumSlots = 2

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
    /// Delay Zweiklang adds on its own per slot (ms), see `SyncDelays`. Only known while a session runs.
    public private(set) var automaticDelays: [Double] = [0, 0]
    /// Each output's own sound processing (stream latency) in ms; what the automatic delays even out.
    public private(set) var processingDelays: [Double] = [0, 0]
    /// The user's extra delay per output (ms), keyed by `OutputTarget.id`, so it follows the device.
    public private(set) var syncOffsets: [String: Double] = [:]
    /// Notice during a running session, e.g. a failed reconnect.
    public private(set) var message: String?
    public var linked = false {
        didSet { defaults.set(linked, forKey: Keys.linked) }
    }
    /// Status line of each slot.
    public private(set) var slotStatus: [PairStatus] = [.none, .none]
    /// Battery of each slot while its Bluetooth link is up.
    public private(set) var slotBattery: [BatteryLevel?] = [nil, nil]
    /// Connect the chosen pairs as soon as the menu opens, so "Listen together" starts at once.
    public var preconnectEnabled = true {
        didSet { defaults.set(preconnectEnabled, forKey: Keys.preconnect) }
    }
    /// Disconnect the guest pairs (every Bluetooth pair after the first) when the session ends,
    /// so they can go back to their owners' iPhones.
    public var releaseGuestOnStop = true {
        didSet { defaults.set(releaseGuestOnStop, forKey: Keys.releaseGuest) }
    }

    /// Called after a volume key changed the volume (for the on-screen display).
    @ObservationIgnored public var onVolumeKeyFeedback: (() -> Void)?
    /// Called when a session becomes active or ends (the volume-key tap only runs meanwhile).
    @ObservationIgnored public var onActiveChange: ((Bool) -> Void)?
    @ObservationIgnored public var connectTimeout: TimeInterval = 12
    @ObservationIgnored public var audioAppearTimeout: TimeInterval = 15
    /// How long to look for audio after a failed Bluetooth call (macOS sometimes connects anyway).
    @ObservationIgnored var unlinkedGrace: TimeInterval = 4
    /// Pauses before the automatic attempts after a pair dropped out of a session.
    @ObservationIgnored var reconnectDelays: [TimeInterval] = [3, 10, 30]
    @ObservationIgnored var releaseTimeout: TimeInterval = 3
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
    @ObservationIgnored private var delayUpdate: Task<Void, Never>?
    /// Delays already written to the current device, so a value the HAL stores differently is not rewritten in a loop.
    @ObservationIgnored private var submittedDelays: (device: AudioObjectID, frames: [String: Int])?

    /// One connection attempt per headphones, shared by preconnect, start and reconnect.
    private struct ConnectAttempt {
        let id: UUID
        let task: Task<AudioDevice?, Never>
        let target: OutputTarget
        /// The Bluetooth link was already up before the attempt, so the attempt did not bring it.
        let linkedBefore: Bool
    }
    /// A pair to release once its Bluetooth link comes up, because it was let go while still connecting.
    private struct LateRelease {
        let target: OutputTarget
        let until: Date
        /// A connection attempt was running, so the link may well come up; quitting waits for it.
        let wasConnecting: Bool
    }
    @ObservationIgnored private var connectAttempts: [String: ConnectAttempt] = [:]
    /// Targets whose last attempt failed without a Bluetooth link.
    @ObservationIgnored private var unreachableTargets: Set<String> = []
    /// Which target had its sound device at the last refresh, to notice a pair dropping out.
    @ObservationIgnored private var presentTargetIDs: [String?] = [nil, nil]
    @ObservationIgnored private var reconnectPolicies: [ReconnectPolicy] = []
    @ObservationIgnored private var reconnectProgress: [(attempt: Int, of: Int)?] = [nil, nil]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectRunID: UUID?
    @ObservationIgnored private var pendingRelease: Task<Void, Never>?
    /// Guest pairs (and pairs taken out of the list) whose connection was still under way, by target ID:
    /// release them if the link comes up late.
    @ObservationIgnored private var releaseWhenLinked: [String: LateRelease] = [:]
    /// Released guest pairs are not connected again by merely opening the menu.
    @ObservationIgnored private var releasedTargetIDs: Set<String> = []
    @ObservationIgnored private var aggregateCheck: Task<Void, Never>?
    /// The session should own the system output; false after the user picked another output.
    @ObservationIgnored private var wantsSystemOutput = false
    /// The output the user picked over the shared one, to undo macOS jumping to returning AirPods.
    @ObservationIgnored private var userOutput: AudioObjectID?
    /// Zweiklang itself moves the system output (rebuilding the shared output); that is no choice of the user.
    @ObservationIgnored private var movingOutput = false
    @ObservationIgnored private var batteries: [String: BatteryLevel] = [:]
    @ObservationIgnored private var batteryRead: UUID?
    @ObservationIgnored private var batteryReadAgain = false
    @ObservationIgnored private var lastBatteryRead: Date?

    private enum Keys {
        static let targets = "targets"
        static let linked = "linked"
        static let previousOutput = "previousOutputUID"
        static let syncOffsets = "syncOffsets"
        static let preconnect = "preconnect"
        static let releaseGuest = "releaseGuestOnStop"
    }

    private var slots: Range<Int> { targets.indices }

    public init(defaults: UserDefaults, bluetooth: BluetoothProviding, multiOutputUID: String = MultiOutputDevice.defaultUID) {
        AudioSystem.configure()
        self.defaults = defaults
        self.bluetooth = bluetooth
        self.multiOutputUID = multiOutputUID
        self.linked = defaults.bool(forKey: Keys.linked)
        self.preconnectEnabled = defaults.object(forKey: Keys.preconnect) as? Bool ?? true
        self.releaseGuestOnStop = defaults.object(forKey: Keys.releaseGuest) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.targets),
           let saved = try? JSONDecoder().decode([OutputTarget?].self, from: data),
           saved.count >= Self.minimumSlots {
            targets = saved
            resizeSlotArrays()
        }
        if let saved = defaults.dictionary(forKey: Keys.syncOffsets) as? [String: Double] {
            syncOffsets = saved.mapValues(SyncDelays.clampManual).filter { $0.value > 0 }
        }
        installSystemListeners()
        bluetooth.onLinkChange = { [weak self] in self?.scheduleRefresh() }
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
        guard targets.indices.contains(slot) else { return }
        if let target { chosenOnPurpose(target) }
        targets[slot] = target
        saveTargets()
        if case .failed = phase { phase = .idle }
        refresh()
        dropUnchosenAttempts()
        preconnect(slots: [slot])
    }

    /// The menu opened: fresh state, battery levels, and the chosen pairs get connected in the background.
    public func menuOpened() {
        refresh()
        refreshBatteries()
        preconnect(slots: Array(slots))
    }

    /// Picked by the user: a guest pair released after the last session may be connected again.
    private func chosenOnPurpose(_ target: OutputTarget) {
        releasedTargetIDs.remove(target.id)
        // A late release from the last session must not take it away.
        releaseWhenLinked[target.id] = nil
    }

    /// Slots with a chosen output, in menu order.
    public var chosenSlots: [Int] { targets.indices.filter { targets[$0] != nil } }

    /// Outputs that are not in any slot yet.
    public var addableTargets: [OutputTarget] {
        candidates.filter { candidate in !targets.contains { $0?.id == candidate.id } }
    }

    /// Slots can only change while no session runs.
    public var canEditOutputs: Bool { !isBusy && phase != .active }

    public func addOutput(_ target: OutputTarget) {
        guard canEditOutputs, !targets.contains(where: { $0?.id == target.id }) else { return }
        chosenOnPurpose(target)
        targets.append(target)
        resizeSlotArrays()
        saveTargets()
        if case .failed = phase { phase = .idle }
        refresh()
        preconnect(slots: [targets.count - 1])
    }

    public func removeOutput(slot: Int) {
        guard canEditOutputs, targets.count > Self.minimumSlots, targets.indices.contains(slot) else { return }
        targets.remove(at: slot)
        slotDevices.remove(at: slot)
        volumes.remove(at: slot)
        slotHasVolume.remove(at: slot)
        automaticDelays.remove(at: slot)
        processingDelays.remove(at: slot)
        slotStatus.remove(at: slot)
        slotBattery.remove(at: slot)
        presentTargetIDs.remove(at: slot)
        reconnectPolicies.remove(at: slot)
        reconnectProgress.remove(at: slot)
        saveTargets()
        if case .failed = phase { phase = .idle }
        refresh()
        dropUnchosenAttempts()
    }

    /// More than two Bluetooth headphones share one radio; macOS then often drops out.
    public var hasManyBluetoothOutputs: Bool {
        targets.compactMap { $0?.bluetoothAddress }.count > 2
    }

    /// Keeps the per-slot arrays as long as `targets`.
    private func resizeSlotArrays() {
        func fitted<T>(_ values: [T], _ filler: T) -> [T] {
            values.count >= targets.count ? Array(values.prefix(targets.count))
                : values + Array(repeating: filler, count: targets.count - values.count)
        }
        slotDevices = fitted(slotDevices, nil)
        volumes = fitted(volumes, 0.5)
        slotHasVolume = fitted(slotHasVolume, false)
        automaticDelays = fitted(automaticDelays, 0)
        processingDelays = fitted(processingDelays, 0)
        if slotStatus.count != targets.count { slotStatus = fitted(slotStatus, .none) }
        if slotBattery.count != targets.count { slotBattery = fitted(slotBattery, nil) }
        presentTargetIDs = fitted(presentTargetIDs, nil)
        reconnectPolicies = fitted(reconnectPolicies, ReconnectPolicy(delays: reconnectDelays))
        reconnectProgress = fitted(reconnectProgress, nil)
    }

    /// Re-reads devices, connection state, volumes and the current system output.
    public func refresh() {
        defer { updateStatuses() }
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

        resizeSlotArrays()
        let devices = targets.map { target in target.flatMap { t in outputs.first(where: t.matches) } }
        if phase == .active, isMuted, var saved = volumesBeforeMute, saved.count == devices.count {
            for slot in devices.indices {
                guard let device = devices[slot], slotDevices[slot]?.id != device.id else { continue }
                // Back while muted: stays silent and gets its own level back on unmute.
                if let level = Volume.get(device.id), level > 0.01 { saved[slot] = level }
                try? Volume.set(0, on: device.id)
            }
            volumesBeforeMute = saved
        }
        if devices.map({ $0?.id }) != slotDevices.map({ $0?.id }) {
            slotHasVolume = devices.map { $0.map { Volume.canControl($0.id) } ?? false }
        }
        releaseLateGuestLinks()
        let appeared = zip(devices, slotDevices).contains { $0.0 != nil && $0.1 == nil }
        slotDevices = devices
        trackPresence()
        if appeared { refreshBatteries() }
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
            trackOutputChoice(aggregate: aggregate)
            syncVolumeObservers()
            readVolumes()
            if !isBusy { applyDelays() }
        }
    }

    private func pickDefaultTargets() {
        let bluetoothTargets = candidates.filter { $0.bluetoothAddress != nil }
        // Own AirPods (name contains the user's first name) first, the guest pair second.
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        let airPods = bluetoothTargets.filter { $0.name.localizedCaseInsensitiveContains("AirPods") }
            .sorted { $0.name.localizedCaseInsensitiveContains(firstName) && !$1.name.localizedCaseInsensitiveContains(firstName) }
        let picks = Array((airPods.count >= 2 ? airPods : bluetoothTargets).prefix(Self.minimumSlots))
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
        let chosen = targets.compactMap { $0 }
        guard chosen.count >= Self.minimumSlots else { return L("Please choose at least two outputs.") }
        return Set(chosen.map(\.id)).count == chosen.count ? nil : L("Please choose different outputs.")
    }

    /// Starts a session, or reconnects missing headphones while one runs.
    public func start() async {
        guard !isBusy else { return }
        if let startProblem {
            phase = .failed(startProblem)
            return
        }
        let chosen = targets.compactMap { $0 }
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
            phase = .working(L("Connecting headphones …"))
            reconnectPolicies = slots.map { _ in ReconnectPolicy(delays: reconnectDelays) }
            reconnectProgress = slots.map { _ in nil }
            releasedTargetIDs = []
            releaseWhenLinked = [:]
            // A guest pair still being released from the last session would vanish right after connecting.
            await pendingRelease?.value
            if cancelRequested { return }
            // Remember the output before connecting: macOS may switch to freshly connected AirPods.
            rememberPreviousOutput()
        }

        log.info("start: \(chosen.map(\.name), privacy: .private(mask: .hash))")
        let found = await withTaskGroup(of: (Int, AudioDevice?).self) { group in
            for (index, target) in chosen.enumerated() {
                group.addTask { (index, await self.ensureAvailable(target)) }
            }
            var found = [AudioDevice?](repeating: nil, count: chosen.count)
            for await (index, device) in group { found[index] = device }
            return found
        }
        if cancelRequested { return } // stop() already cleaned up

        let missingTargets = zip(chosen, found).filter { $0.1 == nil }.map(\.0)
        let missing = missingTargets.map(\.name)
        guard missing.isEmpty else {
            let reason = if missingTargets.contains(where: { $0.bluetoothAddress == nil }) {
                L("Not available: \(missing.joined(separator: ", ")). Check that the outputs are connected and switched on.")
            } else {
                switch missing.count {
                case 1: L("“\(missing[0])” could not be connected. Take the AirPods out of the case, hold them near the Mac and try again.")
                case 2: L("“\(missing[0])” and “\(missing[1])” could not be connected. Take the AirPods out of the case, hold them near the Mac and try again.")
                default: L("These outputs could not be connected: \(missing.joined(separator: ", ")). Take the AirPods out of the case, hold them near the Mac and try again.")
                }
            }
            failStart(wasActive: wasActive, reason: reason)
            return
        }
        let devices = found.compactMap { $0 }

        if !wasActive { phase = .working(L("Setting up the shared output …")) }
        movingOutput = true
        defer { movingOutput = false }
        do {
            let delays = desiredDelays(Array(zip(chosen, devices)))
            let aggregate = try await prepareAggregate(subDeviceUIDs: devices.map(\.uid), extraLatencyFrames: delays.frames)
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
        } else {
            // Fetched back by hand: the automatic attempts may start over.
            reconnectPolicies = slots.map { _ in ReconnectPolicy(delays: reconnectDelays) }
        }
        wantsSystemOutput = true
        userOutput = nil
        phase = .active
        refresh()
        // Sample rates can change once the device runs; delays count in each device's own rate.
        applyDelays()
        refreshBatteries(force: true)
        log.info("active: \(devices.map(\.uid), privacy: .private(mask: .hash)), volumes \(self.volumes, privacy: .private(mask: .hash))")
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
        delayUpdate?.cancel()
        let wasBusy = isBusy
        let hadSession = wasBusy || phase == .active
        if wasBusy { cancelRequested = true }
        aggregateCheck?.cancel()
        aggregateCheck = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectRunID = nil
        reconnectProgress = slots.map { _ in nil }
        let connecting = Set(connectAttempts.keys)
        cancelConnectAttempts()
        endMute()
        message = nil
        cleanUpSession()
        if wasBusy { rollbackOutput() }
        defaults.removeObject(forKey: Keys.previousOutput)
        phase = .idle
        if hadSession && releaseGuestOnStop { releaseGuests(guestPairs, connecting: connecting) }
        refresh()
        log.info("stopped, output now \(AudioSystem.defaultOutputDeviceID().flatMap(AudioSystem.device(id:))?.name ?? "-", privacy: .private(mask: .hash))")
    }

    /// For quitting: ends the session and waits until the guest pairs are released, because macOS only drops
    /// the Bluetooth link while the app still runs. A guest whose connection was still under way is waited for
    /// too, up to `timeout` (the app quits after 5 s in any case).
    public func prepareForQuit(timeout: TimeInterval = 4.5) async {
        stop()
        let deadline = Date().addingTimeInterval(timeout)
        var awaited: Task<Void, Never>?
        while Date() < deadline {
            if let release = pendingRelease, release != awaited {
                await release.value
                awaited = release
                continue
            }
            releaseLateGuestLinks()
            guard pendingRelease == awaited else { continue }
            guard releaseWhenLinked.values.contains(where: \.wasConnecting) else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Gives the headphones their volume back if the session ends while muted.
    private func endMute() {
        if isMuted, let saved = volumesBeforeMute { setDeviceVolumes(saved) }
        isMuted = false
        volumesBeforeMute = nil
    }

    private func cleanUpSession() {
        delayUpdate?.cancel()
        submittedDelays = nil
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
        wantsSystemOutput = true
        userOutput = nil
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
        let isOurs = expected.count >= Self.minimumSlots
            && expected.count == targets.compactMap({ $0 }).count
            && Set(MultiOutputDevice.subDeviceUIDs(aggregate.id)) == Set(expected)
        if isOurs && AudioSystem.defaultOutputDeviceID() == aggregate.id {
            wantsSystemOutput = true
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

    /// The target's sound device, unless its Bluetooth link is being closed (e.g. a guest released at the last
    /// Stop whose close outlasted the wait): that device vanishes any moment.
    private func usableDevice(for target: OutputTarget) -> AudioDevice? {
        if let address = target.bluetoothAddress, bluetooth.isClosing(address: address) { return nil }
        return currentDevice(for: target)
    }

    private func ensureAvailable(_ target: OutputTarget) async -> AudioDevice? {
        if let device = usableDevice(for: target) { return device }
        guard target.bluetoothAddress != nil else { return nil }
        // Also for a link being closed: the attempt waits for the close and then connects again.
        // Joins a preconnect that is still running instead of starting a second attempt.
        return await connectTask(for: target).value
    }

    private func prepareAggregate(subDeviceUIDs: [String], extraLatencyFrames: [String: Int]) async throws -> AudioDevice {
        if let existing = aggregateDevice() {
            // An output that dropped out stays in the composition; keep the device only if it plays on all of them.
            if existing.hasOutput, MultiOutputDevice.subDeviceUIDs(existing.id) == subDeviceUIDs,
               Set(MultiOutputDevice.activeSubDeviceUIDs(existing.id)) == Set(subDeviceUIDs) { return existing }
            // Removing the system output lets macOS pick the next one, maybe the speakers: hand it to headphones first.
            if AudioSystem.defaultOutputDeviceID() == existing.id {
                let handover = subDeviceUIDs.first { BluetoothAddress.fromDeviceUID($0) != nil } ?? subDeviceUIDs[0]
                guard let device = AudioSystem.device(uid: handover), switchOutputAndWait(to: device.id) else {
                    throw AudioError(status: kAudioHardwareIllegalOperationError, operation: L("Switching the audio output"))
                }
            }
            try MultiOutputDevice.destroy(existing.id)
        }
        return try await MultiOutputDevice.create(subDeviceUIDs: subDeviceUIDs, extraLatencyFrames: extraLatencyFrames,
                                                  uid: multiOutputUID)
    }

    private func switchOutputAndWait(to id: AudioObjectID) -> Bool {
        guard (try? AudioSystem.setDefaultOutputDevice(id)) != nil else { return false }
        let deadline = Date().addingTimeInterval(1)
        while AudioSystem.defaultOutputDeviceID() != id, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return AudioSystem.defaultOutputDeviceID() == id
    }

    // MARK: - Connecting

    /// Starts the connection attempt for these headphones, or returns the one already running.
    private func connectTask(for target: OutputTarget) -> Task<AudioDevice?, Never> {
        if let running = connectAttempts[target.id] { return running.task }
        let id = UUID()
        let linkedBefore = target.bluetoothAddress.map(bluetooth.isConnected(address:)) ?? false
        let task = Task { [weak self] () -> AudioDevice? in
            guard let self else { return nil }
            // A release still under way would take the link away again right after it came up.
            await self.pendingRelease?.value
            let device = await self.connectAndWait(target)
            self.connectFinished(target, attempt: id, device: device)
            return device
        }
        connectAttempts[target.id] = ConnectAttempt(id: id, task: task, target: target, linkedBefore: linkedBefore)
        unreachableTargets.remove(target.id)
        updateStatuses()
        return task
    }

    /// Opens the Bluetooth link and waits for the sound device; ends early when the attempt is cancelled.
    private func connectAndWait(_ target: OutputTarget) async -> AudioDevice? {
        guard let address = target.bluetoothAddress else { return nil }
        let linked = await bluetooth.connect(address: address, timeout: connectTimeout)
        log.info("bluetooth connect \(target.name, privacy: .private(mask: .hash)): \(linked, privacy: .private(mask: .hash))")
        // macOS sometimes finishes the connection even when the call reports a failure.
        let deadline = Date().addingTimeInterval(linked ? audioAppearTimeout : unlinkedGrace)
        while Date() < deadline, !Task.isCancelled {
            if usableDevice(for: target) != nil {
                // Give the freshly published device a moment to settle before using it.
                try? await Task.sleep(nanoseconds: 700_000_000)
                return usableDevice(for: target)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if linked, !Task.isCancelled {
            log.error("\(target.name, privacy: .private(mask: .hash)) connected, but no audio device appeared (still in the case?)")
        }
        return nil
    }

    private func connectFinished(_ target: OutputTarget, attempt: UUID, device: AudioDevice?) {
        guard connectAttempts[target.id]?.id == attempt else { return } // cancelled meanwhile
        connectAttempts[target.id] = nil
        if device == nil, let address = target.bluetoothAddress, !bluetooth.isConnected(address: address) {
            unreachableTargets.insert(target.id)
        }
        refresh()
        // The battery is known as soon as the link is up, also for AirPods still in the case.
        if device != nil || target.bluetoothAddress.map(bluetooth.isConnected(address:)) == true { refreshBatteries(force: true) }
    }

    private func cancelConnectAttempts() {
        connectAttempts.values.forEach { $0.task.cancel() }
        connectAttempts = [:]
    }

    /// A pair taken out of the list is no longer connected in the background. If its attempt brought the
    /// Bluetooth link up (or still may), the link is closed again, as for a guest after a session.
    private func dropUnchosenAttempts() {
        let chosen = Set(targets.compactMap { $0?.id })
        let dropped = connectAttempts.values.filter { !chosen.contains($0.target.id) }
        guard !dropped.isEmpty else { return }
        for attempt in dropped {
            attempt.task.cancel()
            connectAttempts[attempt.target.id] = nil
        }
        let ours = dropped.filter { !$0.linkedBefore }.map(\.target)
        releaseGuests(ours, connecting: Set(ours.map(\.id)))
    }

    /// Connects the chosen pairs in the background while no session runs, so a start is instant.
    private func preconnect(slots chosen: [Int]) {
        guard preconnectEnabled, !isBusy, phase != .active else { return }
        for slot in chosen {
            guard let target = targets[slot], target.bluetoothAddress != nil, !releasedTargetIDs.contains(target.id),
                  currentDevice(for: target) == nil, connectAttempts[target.id] == nil else { continue }
            let outputBefore = AudioSystem.defaultOutputDeviceID()
            let task = connectTask(for: target)
            Task { [weak self] in
                guard let device = await task.value else { return }
                self?.undoOutputSwitch(to: device, outputBefore: outputBefore)
            }
        }
    }

    /// macOS likes to move the sound to freshly connected AirPods. Without a session that only surprises,
    /// so switch back, unless a session started meanwhile or the output moved on again.
    private func undoOutputSwitch(to device: AudioDevice, outputBefore: AudioObjectID?) {
        guard !isBusy, phase != .active, let outputBefore, outputBefore != device.id,
              AudioSystem.defaultOutputDeviceID() == device.id,
              AudioSystem.device(id: outputBefore)?.hasOutput == true, AudioSystem.isAlive(outputBefore) else { return }
        log.info("preconnect: sound back to the previous output")
        try? AudioSystem.setDefaultOutputDevice(outputBefore)
    }

    // MARK: - Automatic reconnect

    private func trackPresence() {
        for slot in slots {
            let id = targets[slot]?.id
            let present = slotDevices[slot] != nil
            if present, let id {
                unreachableTargets.remove(id)
                if phase == .active {
                    reconnectPolicies[slot].pairPresent()
                    // Back by itself or fetched back: make sure the shared output plays on it again.
                    if presentTargetIDs[slot] != id { scheduleAggregateCheck() }
                }
            } else if phase == .active, let id, presentTargetIDs[slot] == id {
                pairLost(slot)
            }
            presentTargetIDs[slot] = present ? id : nil
        }
    }

    /// A pair of the running session lost its sound device: back in the case, taken by an iPhone, out of range.
    func pairLost(_ slot: Int) {
        guard phase == .active, targets[slot]?.bluetoothAddress != nil else { return }
        log.info("slot \(slot, privacy: .public) dropped out")
        if reconnectPolicies[slot].pairLost() {
            reconnectProgress[slot] = (reconnectPolicies[slot].used + 1, reconnectPolicies[slot].maxAttempts)
            updateStatuses()
        }
        guard reconnectTask == nil else { return }
        let run = UUID()
        reconnectRunID = run
        reconnectTask = Task { [weak self] in await self?.runAutoReconnect(run) }
    }

    private func missingBluetoothSlots() -> [Int] {
        slots.filter { targets[$0]?.bluetoothAddress != nil && slotDevices[$0] == nil }
    }

    /// One loop for all slots: pause, then try again, within each slot's budget.
    private func runAutoReconnect(_ run: UUID) async {
        defer {
            if reconnectRunID == run {
                reconnectTask = nil
                reconnectRunID = nil
                reconnectProgress = slots.map { _ in nil }
                updateStatuses()
            }
        }
        var reported: Set<Int> = []
        while !Task.isCancelled, phase == .active {
            let missing = missingBluetoothSlots()
            let exhausted = missing.filter { reconnectPolicies[$0].nextDelay == nil && !reported.contains($0) }
            if !exhausted.isEmpty {
                reported.formUnion(exhausted)
                giveUp(exhausted)
            }
            let waiting = missing.filter { reconnectPolicies[$0].nextDelay != nil }
            guard !waiting.isEmpty else { return }
            for slot in waiting {
                reconnectProgress[slot] = (reconnectPolicies[slot].used + 1, reconnectPolicies[slot].maxAttempts)
            }
            updateStatuses()
            let delay = waiting.compactMap { reconnectPolicies[$0].nextDelay }.max() ?? 0
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while isBusy, !Task.isCancelled { try? await Task.sleep(nanoseconds: 300_000_000) } // a manual reconnect runs
            guard !Task.isCancelled, phase == .active else { return }
            // Only real attempts count; a pair that came back by itself during the pause costs nothing.
            let stillMissing = Set(missingBluetoothSlots())
            let attempt = waiting.filter(stillMissing.contains)
            attempt.forEach { reconnectPolicies[$0].takeAttempt() }
            if !attempt.isEmpty { await reconnect(slots: attempt) }
        }
    }

    private func giveUp(_ lost: [Int]) {
        log.error("automatic reconnect gave up for \(lost.count, privacy: .public) pair(s)")
        message = lost.map { slot in
            L("“\(displayName(slot: slot))” could not be brought back automatically. It may be playing on another device, such as an iPhone.")
        }.joined(separator: "\n")
    }

    /// Connects missing pairs again. Unlike "Reconnect" by hand it never ends the session and leaves an
    /// output the user picked meanwhile alone.
    private func reconnect(slots lost: [Int]) async {
        guard !isBusy, phase == .active else { return }
        isBusy = true
        isReconnecting = true
        cancelRequested = false
        defer {
            isBusy = false
            isReconnecting = false
            refresh() // only now a missing shared output ends the session
        }
        for task in lost.compactMap({ targets[$0] }).map({ connectTask(for: $0) }) { _ = await task.value }
        guard !cancelRequested, phase == .active else { return }
        await restoreSharedOutput()
    }

    private func scheduleAggregateCheck() {
        guard aggregateCheck == nil else { return }
        aggregateCheck = Task { [weak self] in
            // Give the HAL a moment to take the returning pair back into the shared output by itself.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            // A reconnect in progress: check once it is done instead of dropping the check.
            while self.isBusy, !Task.isCancelled { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            self.aggregateCheck = nil
            guard self.phase == .active else { return }
            self.isBusy = true
            self.cancelRequested = false
            defer {
                self.isBusy = false
                self.refresh()
            }
            await self.restoreSharedOutput()
        }
    }

    /// While a session runs: picking another output means the user wants it; macOS moving the sound to one
    /// of the session's own pairs (it does that for returning AirPods) does not count as a choice.
    private func trackOutputChoice(aggregate: AudioDevice?) {
        // Also while a pair is being fetched back: only Zweiklang's own switches do not count.
        guard !movingOutput, let current = AudioSystem.defaultOutputDeviceID() else { return }
        // Also a session pair macOS publishes only now, before the device list has it.
        let isSessionOutput = slotDevices.contains { $0?.id == current }
            || AudioSystem.device(id: current).map { device in targets.contains { $0?.matches(device) == true } } == true
        if current == aggregate?.id {
            wantsSystemOutput = true
            userOutput = nil
        } else if !isSessionOutput {
            wantsSystemOutput = false
            userOutput = current
        }
    }

    /// An output is back: the shared output must play on every output that is there (rebuilt if needed, with
    /// each output's delay), and the system output goes where it belongs: to the shared output, or back to what
    /// the user picked meanwhile. Outputs still missing join again once they return.
    private func restoreSharedOutput() async {
        let chosen = targets.compactMap { $0 }
        let outputs = chosen.compactMap { target in currentDevice(for: target).map { (target, $0) } }
        let devices = outputs.map(\.1)
        guard !devices.isEmpty else { return }
        movingOutput = true
        defer { movingOutput = false }
        do {
            let aggregate: AudioDevice
            if devices.count < chosen.count, let existing = aggregateDevice(), existing.hasOutput,
               Set(devices.map(\.uid)).isSubset(of: MultiOutputDevice.activeSubDeviceUIDs(existing.id)) {
                aggregate = existing // the ones that are back already play; no rebuild while others are missing
            } else {
                let delays = desiredDelays(outputs)
                aggregate = try await prepareAggregate(subDeviceUIDs: devices.map(\.uid), extraLatencyFrames: delays.frames)
            }
            if cancelRequested { cleanUpSession(); return } // stopped meanwhile
            let current = AudioSystem.defaultOutputDeviceID()
            if wantsSystemOutput {
                if current != aggregate.id { try await switchOutput(to: aggregate) }
            } else if let current, devices.contains(where: { $0.id == current }), let userOutput, AudioSystem.isAlive(userOutput) {
                try? AudioSystem.setDefaultOutputDevice(userOutput) // macOS jumped to the returning AirPods
            }
            log.info("shared output plays on \(devices.count, privacy: .public) of \(chosen.count, privacy: .public) outputs")
        } catch {
            log.error("reconnect: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
    }

    // MARK: - Releasing the guest pairs

    /// The first Bluetooth pair in the list belongs to the Mac's owner.
    private var ownPair: OutputTarget? { targets.lazy.compactMap { $0 }.first { $0.bluetoothAddress != nil } }

    /// Every other Bluetooth pair is a guest's.
    private var guestPairs: [OutputTarget] {
        let pairs = targets.compactMap { $0 }.filter { $0.bluetoothAddress != nil }
        guard let own = pairs.first else { return [] }
        return pairs.dropFirst().filter { $0.id != own.id }
    }

    /// Disconnects guest pairs after a session so they can go back to their owners' iPhones.
    /// `connecting`: targets whose connection attempt was still running.
    private func releaseGuests(_ guests: [OutputTarget], connecting: Set<String> = []) {
        var addresses: [String] = []
        for guest in guests {
            guard let address = guest.bluetoothAddress else { continue }
            releasedTargetIDs.insert(guest.id)
            guard bluetooth.isConnected(address: address) else {
                // A native connection may still finish after Stop (even one whose wait already timed out).
                releaseWhenLinked[guest.id] = LateRelease(target: guest, until: Date().addingTimeInterval(connectTimeout + 10),
                                                          wasConnecting: connecting.contains(guest.id))
                continue
            }
            if let device = currentDevice(for: guest), AudioSystem.defaultOutputDeviceID() == device.id {
                // Without the guest pair macOS would pick the next output, maybe the speakers.
                guard let own = ownPair.flatMap({ currentDevice(for: $0) }), switchOutputAndWait(to: own.id) else {
                    log.info("guest pair kept: it is the only headphone output")
                    continue
                }
            }
            addresses.append(address)
        }
        guard !addresses.isEmpty else { return }
        let previous = pendingRelease
        let timeout = releaseTimeout
        pendingRelease = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // All at once: quitting waits for them.
            let releases = addresses.map { address in
                Task { await self.bluetooth.disconnect(address: address, timeout: timeout) }
            }
            for release in releases {
                let released = await release.value
                log.info("guest pair released: \(released, privacy: .public)")
            }
            self.refresh()
        }
    }

    /// A connection finished only after its pair was let go (Stop, or taken out of the list): release it now,
    /// unless a new session took it over or it was chosen again.
    private func releaseLateGuestLinks() {
        guard !releaseWhenLinked.isEmpty else { return }
        let now = Date()
        let chosen = Set(targets.compactMap { $0?.id })
        let guests = Set(guestPairs.map(\.id))
        // Expired, or now the owner's pair: nothing to release any more.
        releaseWhenLinked = releaseWhenLinked.filter { id, late in
            now < late.until && (guests.contains(id) || !chosen.contains(id))
        }
        // A new start clears the markers, so a busy flag here only means the cancelled start is winding down.
        guard phase != .active else { return }
        let late = releaseWhenLinked.values.map(\.target).filter { target in
            target.bluetoothAddress.map(bluetooth.isConnected(address:)) == true
        }
        guard !late.isEmpty else { return }
        late.forEach { releaseWhenLinked[$0.id] = nil }
        releaseGuests(late)
    }

    // MARK: - Status and battery

    private func updateStatuses() {
        let statuses = slots.map { status(slot: $0) }
        if statuses != slotStatus { slotStatus = statuses }
        let levels: [BatteryLevel?] = slots.map { slot in
            guard statuses[slot] == .connected || statuses[slot] == .inCase,
                  let address = targets[slot]?.bluetoothAddress else { return nil }
            return batteries[BluetoothAddress.normalized(address)]
        }
        if levels != slotBattery { slotBattery = levels }
    }

    private func status(slot: Int) -> PairStatus {
        guard let target = targets[slot] else { return .none }
        if slotDevices[slot] != nil { return .connected }
        if let progress = reconnectProgress[slot] { return .reconnecting(attempt: progress.attempt, of: progress.of) }
        if connectAttempts[target.id] != nil { return .connecting }
        guard let address = target.bluetoothAddress else { return .unavailable }
        if bluetooth.isConnected(address: address) { return .inCase }
        return unreachableTargets.contains(target.id) ? .unreachable : .notConnected
    }

    /// Reads battery levels in the background, one read at a time and at most every 10 s unless forced.
    private func refreshBatteries(force: Bool = false) {
        guard targets.contains(where: { $0?.bluetoothAddress != nil }) else { return }
        if batteryRead != nil {
            if force { batteryReadAgain = true }
            return
        }
        if !force, let last = lastBatteryRead, Date().timeIntervalSince(last) < 10 { return }
        let read = UUID()
        batteryRead = read
        lastBatteryRead = Date()
        Task { [weak self] in
            guard let self else { return }
            let levels = await self.bluetooth.batteryLevels()
            guard self.batteryRead == read else { return }
            self.batteryRead = nil
            self.batteries = levels
            self.updateStatuses()
            if self.batteryReadAgain {
                self.batteryReadAgain = false
                self.refreshBatteries(force: true)
            }
        }
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
        let connected = slotDevices.compactMap { $0 }
        let headphones = connected.first { BluetoothAddress.fromDeviceUID($0.uid) != nil }
        guard let target = previousOutput() ?? headphones ?? connected.first else { return }
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

    /// Volume keys: every output moves by the same step, so their differences stay.
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

    // MARK: - Timing

    public func syncOffset(slot: Int) -> Double {
        guard targets.indices.contains(slot), let target = targets[slot] else { return 0 }
        return syncOffsets[target.id] ?? 0
    }

    /// Extra delay for one output, saved per device. While a session runs it takes effect shortly after
    /// the last change: every change rebuilds the device's timing, which can cause a short dropout.
    public func setSyncOffset(_ milliseconds: Double, slot: Int) {
        guard targets.indices.contains(slot), let target = targets[slot] else { return }
        let value = SyncDelays.clampManual(milliseconds)
        syncOffsets[target.id] = value > 0 ? value : nil
        defaults.set(syncOffsets, forKey: Keys.syncOffsets)
        delayUpdate?.cancel()
        guard phase == .active else { return }
        delayUpdate = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, self.phase == .active, !self.isBusy else { return }
            self.applyDelays()
        }
    }

    /// The output the others wait for: the one with the longest own sound processing, if anyone waits at all.
    public var timingReferenceSlot: Int? {
        let slots = chosenSlots.filter { slotDevices[$0] != nil }
        guard slots.contains(where: { automaticDelays[$0] >= 0.5 }) else { return nil }
        return slots.max { processingDelays[$0] < processingDelays[$1] }
    }

    /// Delay per output: the automatic part and the own processing (ms, for display) and the frames for
    /// `latency-out`, keyed by device UID.
    private func desiredDelays(_ outputs: [(OutputTarget, AudioDevice)])
        -> (automatic: [Double], processing: [Double], frames: [String: Int]) {
        let timings = outputs.map { OutputTiming.read($0.1.id) }
        let automatic = SyncDelays.automatic(timings)
        var frames: [String: Int] = [:]
        for (index, (target, device)) in outputs.enumerated() {
            // Unknown rate (device busy or just vanishing): leave its delay as it is.
            guard timings[index].sampleRate > 0 else { continue }
            let total = automatic[index] + (syncOffsets[target.id] ?? 0)
            frames[device.uid] = SyncDelays.frames(milliseconds: total, sampleRate: timings[index].sampleRate)
        }
        return (automatic, timings.map(\.streamLatencyMilliseconds), frames)
    }

    /// Brings the running device's delays in line with the wanted ones; writes only when something differs,
    /// so the HAL notification it causes does not loop.
    func applyDelays() {
        guard let aggregate = aggregateDevice() else { return }
        let slots = slotDevices.indices.filter { slotDevices[$0] != nil && targets[$0] != nil }
        let outputs = slots.map { (targets[$0]!, slotDevices[$0]!) }
        let delays = desiredDelays(outputs)
        var automatic = [Double](repeating: 0, count: targets.count)
        var processing = [Double](repeating: 0, count: targets.count)
        for (index, slot) in slots.enumerated() {
            automatic[slot] = delays.automatic[index]
            processing[slot] = delays.processing[index]
        }
        if automatic != automaticDelays { automaticDelays = automatic }
        if processing != processingDelays { processingDelays = processing }

        let current = MultiOutputDevice.extraLatencyFrames(aggregate.id)
        let submitted = submittedDelays?.device == aggregate.id ? submittedDelays?.frames ?? [:] : [:]
        let changes = delays.frames.filter { uid, frames in
            (current[uid].map { $0 != frames } ?? false) && submitted[uid] != frames
        }
        guard !changes.isEmpty else { return }
        do {
            try MultiOutputDevice.setExtraLatency(aggregate.id, frames: changes)
            // Only a successful write counts; a failed one is tried again on the next refresh.
            submittedDelays = (aggregate.id, submitted.merging(changes) { $1 })
            log.info("delays \(changes, privacy: .private(mask: .hash))")
        } catch {
            log.error("delays: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
    }

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
            // Delays count in the device's own sample rate; a rate change needs new values.
            if let listener = PropertyListener(objectID: id, address: propertyAddress(kAudioDevicePropertyNominalSampleRate), handler: { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }) {
                volumeListeners.append(listener)
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
