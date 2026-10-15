import AudioToolbox
import CoreAudio
import Foundation

/// Error from a Core Audio call, with a German message for the UI.
public struct AudioError: LocalizedError {
    public let status: OSStatus
    public let operation: String

    public var errorDescription: String? { L("\(operation) failed (code \(String(status))).") }
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

/// Thin typed wrappers around the AudioObject property API.
enum HAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func has(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(id, &address)
    }

    static func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address),
              AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func value<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func setValue<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T, operation: String) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else { throw AudioError(status: status, operation: operation) }
    }

    static func string(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        cfObject(id, address) as? String
    }

    static func cfObject(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> CFTypeRef? {
        var address = address
        var value: Unmanaged<CFTypeRef>?
        var size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue()
    }

    static func objectIDs(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        // A device can vanish between the two calls; only the returned size is valid.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}

/// Keeps a HAL property listener alive and removes it on `remove()` or deinit.
final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init?(objectID: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        self.objectID = objectID
        self.address = address
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(objectID, &self.address, DispatchQueue.main, block) == noErr else {
            return nil
        }
        active = true
    }

    func remove() {
        guard active else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
        active = false
    }

    deinit { remove() }
}
