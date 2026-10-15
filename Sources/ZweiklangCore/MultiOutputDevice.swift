import CoreAudio
import Foundation

/// The multi-output device ("Multi-Output Device" in Audio MIDI Setup) that plays
/// the same audio on every sub-device.
public enum MultiOutputDevice {
    public static let defaultUID = "ch.moritz.zweiklang.multiausgang"
    /// Shown in the Sound settings while a session runs.
    public static var defaultName: String { L("Zweiklang (shared output)") }

    /// Creates the device. The first sub-device is the clock source, all others get drift correction,
    /// the same layout Audio-MIDI-Setup uses (`stacked = 1`). `extraLatencyFrames` delays single
    /// sub-devices (frames in that device's own sample rate).
    @discardableResult
    public static func create(subDeviceUIDs: [String], extraLatencyFrames: [String: Int] = [:],
                              uid: String = defaultUID, name: String = defaultName) async throws -> AudioDevice {
        precondition(!subDeviceUIDs.isEmpty)
        let subDevices: [[String: Any]] = subDeviceUIDs.enumerated().map { index, subUID in
            [kAudioSubDeviceUIDKey: subUID,
             kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1,
             kAudioSubDeviceExtraOutputLatencyKey: max(extraLatencyFrames[subUID] ?? 0, 0)]
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
        // The HAL publishes the sub-devices asynchronously; wait until the device can play on every member.
        let deadline = Date().addingTimeInterval(3)
        var playable: AudioDevice?
        while Date() < deadline {
            if let device = AudioSystem.device(id: id), device.hasOutput {
                playable = device
                if activeSubDeviceCount(id) >= subDeviceUIDs.count { return device }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // A member that never starts (e.g. it vanished meanwhile) should not block the others.
        if let playable { return playable }
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

    static func activeSubDeviceCount(_ id: AudioObjectID) -> Int {
        HAL.objectIDs(id, propertyAddress(kAudioAggregateDevicePropertyActiveSubDeviceList)).count
    }

    public static func find(uid: String = defaultUID) -> AudioDevice? {
        AudioSystem.device(uid: uid)
    }

    public static func composition(_ id: AudioObjectID) -> [String: Any] {
        HAL.cfObject(id, propertyAddress(kAudioAggregateDevicePropertyComposition)) as? [String: Any] ?? [:]
    }

    private static func subDevices(_ id: AudioObjectID) -> [[String: Any]] {
        composition(id)[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
    }

    public static func subDeviceUIDs(_ id: AudioObjectID) -> [String] {
        subDevices(id).compactMap { $0[kAudioSubDeviceUIDKey] as? String }
    }

    /// Sub-devices that really play right now. A pair that dropped out stays in the composition but is missing here.
    public static func activeSubDeviceUIDs(_ id: AudioObjectID) -> [String] {
        HAL.objectIDs(id, propertyAddress(kAudioAggregateDevicePropertyActiveSubDeviceList)).compactMap { AudioSystem.device(id: $0)?.uid }
    }

    public static func isStacked(_ id: AudioObjectID) -> Bool {
        (composition(id)[kAudioAggregateDeviceIsStackedKey] as? Int) == 1
    }

    /// Delay of each sub-device in frames, keyed by its UID.
    public static func extraLatencyFrames(_ id: AudioObjectID) -> [String: Int] {
        var result: [String: Int] = [:]
        for sub in subDevices(id) {
            guard let uid = sub[kAudioSubDeviceUIDKey] as? String else { continue }
            result[uid] = (sub[kAudioSubDeviceExtraOutputLatencyKey] as? NSNumber)?.intValue ?? 0
        }
        return result
    }

    /// Changes the delay of sub-devices while the device keeps playing. Only writing the whole composition
    /// takes effect; the sub-device's own extra-latency property is accepted but ignored (macOS 26).
    public static func setExtraLatency(_ id: AudioObjectID, frames: [String: Int]) throws {
        var composition = composition(id)
        guard var subDevices = composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] else {
            throw AudioError(status: kAudioHardwareBadDeviceError, operation: L("Adjusting the timing"))
        }
        for index in subDevices.indices {
            guard let uid = subDevices[index][kAudioSubDeviceUIDKey] as? String, let value = frames[uid] else { continue }
            subDevices[index][kAudioSubDeviceExtraOutputLatencyKey] = max(value, 0)
        }
        composition[kAudioAggregateDeviceSubDeviceListKey] = subDevices
        try HAL.setValue(id, propertyAddress(kAudioAggregateDevicePropertyComposition), composition as CFDictionary,
                         operation: L("Adjusting the timing"))
    }
}
