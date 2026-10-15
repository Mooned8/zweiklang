import CoreAudio
import Foundation

/// The multi-output device ("Multi-Output Device" in Audio MIDI Setup) that plays
/// the same audio on every sub-device.
public enum MultiOutputDevice {
    public static let defaultUID = "ch.moritz.zweiklang.multiausgang"
    /// Shown in the Sound settings while a session runs.
    public static var defaultName: String { L("Zweiklang (both headphones)") }

    /// Creates the device. The first sub-device is the clock source, all others get drift correction,
    /// the same layout Audio-MIDI-Setup uses (`stacked = 1`).
    @discardableResult
    public static func create(subDeviceUIDs: [String], uid: String = defaultUID, name: String = defaultName) async throws -> AudioDevice {
        precondition(!subDeviceUIDs.isEmpty)
        let subDevices: [[String: Any]] = subDeviceUIDs.enumerated().map { index, subUID in
            [kAudioSubDeviceUIDKey: subUID, kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey: subDeviceUIDs[0],
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceIsPrivateKey: 0,
        ]
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else {
            throw AudioError(status: status, operation: L("Creating the shared output"))
        }
        // The HAL publishes the sub-devices asynchronously; wait until the device can play.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let device = AudioSystem.device(id: id), device.hasOutput { return device }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? destroy(id)
        throw AudioError(status: kAudioHardwareBadDeviceError, operation: L("Activating the shared output"))
    }

    public static func destroy(_ id: AudioObjectID) throws {
        let status = AudioHardwareDestroyAggregateDevice(id)
        guard status == noErr else { throw AudioError(status: status, operation: L("Removing the shared output")) }
        // Removal is asynchronous in the HAL; wait so a new device with the same UID does not collide.
        let deadline = Date().addingTimeInterval(1)
        while AudioSystem.deviceIDs().contains(id) {
            guard Date() < deadline else {
                throw AudioError(status: kAudioHardwareBadDeviceError, operation: L("Removing the shared output"))
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    public static func find(uid: String = defaultUID) -> AudioDevice? {
        AudioSystem.device(uid: uid)
    }

    public static func composition(_ id: AudioObjectID) -> [String: Any] {
        HAL.cfObject(id, propertyAddress(kAudioAggregateDevicePropertyComposition)) as? [String: Any] ?? [:]
    }

    public static func subDeviceUIDs(_ id: AudioObjectID) -> [String] {
        (composition(id)[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? [])
            .compactMap { $0[kAudioSubDeviceUIDKey] as? String }
    }

    public static func isStacked(_ id: AudioObjectID) -> Bool {
        (composition(id)[kAudioAggregateDeviceIsStackedKey] as? Int) == 1
    }
}
