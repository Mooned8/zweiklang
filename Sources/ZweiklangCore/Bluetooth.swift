import Foundation
import IOBluetooth

public struct BluetoothHeadphone: Hashable, Sendable {
    public let address: String
    public let name: String

    public init(address: String, name: String) {
        self.address = address
        self.name = name
    }
}

public enum BluetoothAddress {
    /// "12:34:56:78:9A:BC" or "12-34-56-78-9a-bc" -> "123456789abc"
    public static func normalized(_ address: String) -> String {
        address.lowercased().filter { $0.isHexDigit }
    }

    /// Core Audio names Bluetooth devices like "12-34-56-78-9A-BC:output".
    public static func matches(deviceUID uid: String, address: String) -> Bool {
        let wanted = normalized(address)
        guard wanted.count == 12, let found = fromDeviceUID(uid) else { return false }
        return normalized(found) == wanted
    }

    /// Reads the address from a Core Audio Bluetooth UID, nil for other devices.
    public static func fromDeviceUID(_ uid: String) -> String? {
        let prefix = uid.split(separator: ":").first.map(String.init) ?? uid
        let parts = prefix.split(separator: "-")
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.joined(separator: "-").uppercased()
    }
}

/// Charge in percent (0…100) as macOS reports it for connected headphones.
public struct BatteryLevel: Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public var chargingCase: Int?
    /// Headphones with one battery (AirPods Max, most other brands).
    public var main: Int?

    public init(left: Int? = nil, right: Int? = nil, chargingCase: Int? = nil, main: Int? = nil) {
        self.left = left
        self.right = right
        self.chargingCase = chargingCase
        self.main = main
    }

    /// The earbud that runs out first, or the single battery.
    public var lowest: Int? { [left, right].compactMap { $0 }.min() ?? main }
}

/// Reads battery levels from `system_profiler -json SPBluetoothDataType`. Neither IOBluetooth nor the
/// IORegistry publish them for AirPods. The JSON is no API contract, so anything unexpected gives no value.
public enum BatteryReport {
    public static func parse(_ data: Data) -> [String: BatteryLevel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var levels: [String: BatteryLevel] = [:]
        // Only connected devices: macOS keeps old values for the others.
        for controller in controllers {
            for case let device as [String: Any] in (controller["device_connected"] as? [[String: Any]] ?? []).flatMap(\.values) {
                guard let address = device["device_address"] as? String else { continue }
                let level = BatteryLevel(
                    left: percent(device["device_batteryLevelLeft"]),
                    right: percent(device["device_batteryLevelRight"]),
                    chargingCase: percent(device["device_batteryLevelCase"]),
                    main: percent(device["device_batteryLevelMain"])
                )
                if level != BatteryLevel() { levels[BluetoothAddress.normalized(address)] = level }
            }
        }
        return levels
    }

    /// "98%" -> 98
    static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String, let number = Int(text.filter(\.isNumber)), (0...100).contains(number) else { return nil }
        return number
    }

    /// Runs off the main thread; nil if the tool fails or takes too long.
    static func readSystemProfiler() async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["-json", "-timeout", "10", "SPBluetoothDataType"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // system_profiler has its own -timeout, but never let a stuck tool hold the menu's battery display.
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if process.isRunning { process.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}

/// What the session needs from Bluetooth; replaced by a stub in tests.
@MainActor
public protocol BluetoothProviding: AnyObject {
    func pairedHeadphones() -> [BluetoothHeadphone]
    /// Opens the Bluetooth link. Audio becomes available a few seconds later.
    func connect(address: String, timeout: TimeInterval) async -> Bool
    /// The Bluetooth link is up (AirPods in the case have a link but no audio device).
    func isConnected(address: String) -> Bool
    /// Closes the link and waits until it is down, so the headphones are free for another device.
    func disconnect(address: String, timeout: TimeInterval) async -> Bool
    /// A close is still running (it can outlast `disconnect`'s wait); the link and sound device go away any moment.
    func isClosing(address: String) -> Bool
    /// Battery levels of connected headphones, keyed by `BluetoothAddress.normalized`.
    func batteryLevels() async -> [String: BatteryLevel]
    /// Called when any Bluetooth link comes up or goes down.
    var onLinkChange: (() -> Void)? { get set }
}

@MainActor
public final class BluetoothConnector: NSObject, BluetoothProviding {
    /// One native connection attempt per headphones; later callers wait for the same one.
    private struct Pending {
        let native: NativeAttempt
        var waiters: [UUID: CheckedContinuation<Bool, Never>]
    }
    private var pending: [String: Pending] = [:]
    /// Attempts given up on stay alive until IOBluetooth calls them back (it does not retain its target).
    private var retired: [UUID: NativeAttempt] = [:]
    /// closeConnection() calls still running; a new connection waits for them, or they would drop it.
    private var closing: [String: Task<Void, Never>] = [:]
    private var connectNotification: IOBluetoothUserNotification?
    public var onLinkChange: (() -> Void)?

    public override init() {
        super.init()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(linkUp(_:device:)))
    }

    public func pairedHeadphones() -> [BluetoothHeadphone] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.compactMap { device in
            guard let address = device.addressString else { return nil }
            let name = device.name ?? address
            let isAudio = device.deviceClassMajor == 0x04 // kBluetoothDeviceClassMajorAudio
            guard isAudio || name.localizedCaseInsensitiveContains("AirPods") else { return nil }
            return BluetoothHeadphone(address: address.uppercased().replacingOccurrences(of: ":", with: "-"), name: name)
        }
    }

    public func connect(address: String, timeout: TimeInterval) async -> Bool {
        let key = BluetoothAddress.normalized(address)
        guard await waitForClose(key, timeout: timeout) else { return false }
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        if device.isConnected() { return true }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                // A native attempt whose callback never came must not block new ones forever.
                if let stale = pending[key], Date().timeIntervalSince(stale.native.started) > 60 {
                    retire(key, success: device.isConnected())
                }
                if pending[key] != nil {
                    pending[key]?.waiters[waiter] = continuation
                } else {
                    let native = NativeAttempt(key: key, owner: self)
                    pending[key] = Pending(native: native, waiters: [waiter: continuation])
                    // Asynchronous variant: IOBluetooth calls the attempt's connectionComplete(_:status:) on the main run loop.
                    if device.openConnection(native) != kIOReturnSuccess {
                        nativeFinished(native, success: false)
                        return
                    }
                }
                // The timeout only ends this caller's wait; the native attempt stays registered until its callback.
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(key, waiter: waiter, success: device.isConnected())
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(key, waiter: waiter, success: false) }
        }
    }

    public func isConnected(address: String) -> Bool {
        IOBluetoothDevice(addressString: address)?.isConnected() ?? false
    }

    public func disconnect(address: String, timeout: TimeInterval) async -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        guard device.isConnected() else { return true }
        // closeConnection() waits for bluetoothd; never let it hold the main thread (and with it, quitting).
        let key = BluetoothAddress.normalized(address)
        let close = Task.detached(priority: .userInitiated) { _ = IOBluetoothDevice(addressString: address)?.closeConnection() }
        closing[key] = close
        Task { [weak self] in
            await close.value
            if self?.closing[key] == close { self?.closing[key] = nil }
        }
        // The link goes down a moment later, and only while this app still runs.
        let deadline = Date().addingTimeInterval(timeout)
        while device.isConnected(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !device.isConnected()
    }

    public func isClosing(address: String) -> Bool {
        closing[BluetoothAddress.normalized(address)] != nil
    }

    public func batteryLevels() async -> [String: BatteryLevel] {
        guard let data = await BatteryReport.readSystemProfiler() else { return [:] }
        return BatteryReport.parse(data)
    }

    /// Waits, bounded and cancellable, for a closeConnection() still running for these headphones.
    /// False if it is still running: then no new connection is opened that it could drop.
    private func waitForClose(_ key: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while closing[key] != nil {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    fileprivate func nativeFinished(_ native: NativeAttempt, success: Bool) {
        retired.removeValue(forKey: native.id)
        // A late callback of an attempt that was given up on must not answer a newer one.
        guard pending[native.key]?.native === native, let entry = pending.removeValue(forKey: native.key) else { return }
        entry.waiters.values.forEach { $0.resume(returning: success) }
    }

    @objc private func linkUp(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(linkDown(_:device:)))
        onLinkChange?()
    }

    @objc private func linkDown(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        onLinkChange?()
    }

    private func finish(_ key: String, waiter: UUID, success: Bool) {
        guard let continuation = pending[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: success)
    }

    private func retire(_ key: String, success: Bool) {
        guard let entry = pending.removeValue(forKey: key) else { return }
        retired[entry.native.id] = entry.native
        entry.waiters.values.forEach { $0.resume(returning: success) }
    }
}

/// Callback target of one `openConnection`, so its answer can be told apart from a later attempt's.
@MainActor
private final class NativeAttempt: NSObject {
    let id = UUID()
    let key: String
    let started = Date()
    weak var owner: BluetoothConnector?

    init(key: String, owner: BluetoothConnector) {
        self.key = key
        self.owner = owner
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        owner?.nativeFinished(self, success: status == kIOReturnSuccess || device?.isConnected() == true)
    }
}
