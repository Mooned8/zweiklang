import AudioToolbox
import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transportType: UInt32
    public let outputChannels: Int
    /// Some virtual devices (e.g. Microsoft Teams Audio) refuse to be the system output.
    public var canBeDefaultOutput = true

    public var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
    public var hasOutput: Bool { outputChannels > 0 }
}

/// System-wide device list and default output.
public enum AudioSystem {
    private static let configureOnce: Void = {
        // Let the HAL deliver notifications on its own thread instead of the main run loop,
        // so property reads stay current even while the main thread waits.
        var runLoop: CFRunLoop? = nil
        var address = propertyAddress(kAudioHardwarePropertyRunLoop)
        _ = withUnsafeMutablePointer(to: &runLoop) {
            AudioObjectSetPropertyData(HAL.systemObject, &address, 0, nil, UInt32(MemoryLayout<CFRunLoop?>.size), $0)
        }
    }()

    public static func configure() { _ = configureOnce }

    public static func deviceIDs() -> [AudioObjectID] {
        HAL.objectIDs(HAL.systemObject, propertyAddress(kAudioHardwarePropertyDevices))
    }

    /// Every published device, including ones that are currently not usable.
    public static func allDevices() -> [AudioDevice] {
        deviceIDs().compactMap(device(id:))
    }

    /// Real, usable output devices (no aggregates), e.g. AirPods, speakers, USB DACs.
    public static func outputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasOutput && !$0.isAggregate && isAlive($0.id) }
    }

    public static func isAlive(_ id: AudioObjectID) -> Bool {
        HAL.value(id, propertyAddress(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) == 1
    }

    public static func device(id: AudioObjectID) -> AudioDevice? {
        guard let uid = HAL.string(id, propertyAddress(kAudioDevicePropertyDeviceUID)) else { return nil }
        let canBeDefault = propertyAddress(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput)
        var device = AudioDevice(
            id: id,
            uid: uid,
            name: HAL.string(id, propertyAddress(kAudioObjectPropertyName)) ?? uid,
            transportType: HAL.value(id, propertyAddress(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0,
            outputChannels: outputChannelCount(id)
        )
        device.canBeDefaultOutput = (HAL.value(id, canBeDefault, initial: UInt32(1)) ?? 1) != 0
        return device
    }

    /// Direct lookup by UID, without reading every device.
    public static func device(uid: String) -> AudioDevice? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(HAL.systemObject, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return device(id: id)
    }

    public static func defaultOutputDeviceID() -> AudioObjectID? {
        let id = HAL.value(HAL.systemObject, propertyAddress(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID(0))
        return id == 0 ? nil : id
    }

    public static func setDefaultOutputDevice(_ id: AudioObjectID) throws {
        try HAL.setValue(HAL.systemObject, propertyAddress(kAudioHardwarePropertyDefaultOutputDevice), id,
                         operation: L("Switching the audio output"))
    }

    static func outputChannelCount(_ id: AudioObjectID) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Output volume of a single device, 0.0 ... 1.0.
public enum Volume {
    private static let output = kAudioObjectPropertyScopeOutput
    private static let virtualMain = propertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: output)

    private static func scalar(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        propertyAddress(kAudioDevicePropertyVolumeScalar, scope: output, element: element)
    }

    /// Main element if it has a volume control, otherwise the individual channels.
    private static func channelElements(_ id: AudioObjectID) -> [AudioObjectPropertyElement] {
        if HAL.isSettable(id, scalar(kAudioObjectPropertyElementMain)) { return [kAudioObjectPropertyElementMain] }
        let count = max(AudioSystem.outputChannelCount(id), 2)
        return (1...UInt32(count)).filter { HAL.isSettable(id, scalar($0)) }
    }

    public static func canControl(_ id: AudioObjectID) -> Bool {
        HAL.isSettable(id, virtualMain) || !channelElements(id).isEmpty
    }

    public static func get(_ id: AudioObjectID) -> Float? {
        if HAL.has(id, virtualMain), let value = HAL.value(id, virtualMain, initial: Float32(0)) { return value }
        // Loudest channel = perceived volume; keeps the reading stable when the balance is off-center.
        return channelElements(id).compactMap { HAL.value(id, scalar($0), initial: Float32(0)) }.max()
    }

    public static func set(_ value: Float, on id: AudioObjectID) throws {
        let value = min(max(value, 0), 1)
        if HAL.isSettable(id, virtualMain) {
            try HAL.setValue(id, virtualMain, Float32(value), operation: L("Setting the volume"))
            return
        }
        let elements = channelElements(id)
        guard !elements.isEmpty else {
            throw AudioError(status: kAudioHardwareUnknownPropertyError, operation: L("Setting the volume"))
        }
        // Scale all channels together so the left/right balance stays as it was.
        let current = elements.map { HAL.value(id, scalar($0), initial: Float32(0)) ?? 0 }
        let loudest = current.max() ?? 0
        for (element, level) in zip(elements, current) {
            let target = loudest > 0.001 ? level / loudest * value : value
            try HAL.setValue(id, scalar(element), Float32(target), operation: L("Setting the volume"))
        }
    }

    /// Fires when the device volume changes, no matter who changed it.
    static func observe(_ id: AudioObjectID, handler: @escaping () -> Void) -> [PropertyListener] {
        [
            PropertyListener(objectID: id, address: virtualMain, handler: handler),
            PropertyListener(objectID: id, address: scalar(kAudioObjectPropertyElementWildcard), handler: handler),
        ].compactMap { $0 }
    }
}
