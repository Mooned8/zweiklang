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

/// What the session needs from Bluetooth; replaced by a stub in tests.
@MainActor
public protocol BluetoothProviding: AnyObject {
    func pairedHeadphones() -> [BluetoothHeadphone]
    /// Opens the Bluetooth link. Audio becomes available a few seconds later.
    func connect(address: String, timeout: TimeInterval) async -> Bool
}

@MainActor
public final class BluetoothConnector: NSObject, BluetoothProviding {
    private var pending: [String: (attempt: UUID, continuation: CheckedContinuation<Bool, Never>)] = [:]

    public override init() { super.init() }

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
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        if device.isConnected() { return true }
        let key = BluetoothAddress.normalized(address)
        if pending[key] != nil { return false }
        let attempt = UUID()
        return await withCheckedContinuation { continuation in
            pending[key] = (attempt, continuation)
            // Asynchronous variant: IOBluetooth calls connectionComplete(_:status:) on the main run loop.
            if device.openConnection(self) != kIOReturnSuccess {
                finish(key, success: false)
                return
            }
            // The timeout only ends its own attempt, never a later one for the same headphones.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(key, success: device.isConnected(), attempt: attempt)
            }
        }
    }

    @objc public func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let address = device?.addressString else { return }
        finish(BluetoothAddress.normalized(address), success: status == kIOReturnSuccess)
    }

    private func finish(_ key: String, success: Bool, attempt: UUID? = nil) {
        guard let entry = pending[key], attempt == nil || entry.attempt == attempt else { return }
        pending.removeValue(forKey: key)
        entry.continuation.resume(returning: success)
    }
}
