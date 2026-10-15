import AppKit
import ApplicationServices
import CoreGraphics

public enum MediaKey: Equatable, Sendable {
    case volumeUp, volumeDown, mute
}

public struct MediaKeyEvent: Equatable, Sendable {
    public let key: MediaKey
    public let isDown: Bool
    public let isRepeat: Bool
    /// Option+Shift held: quarter steps, like macOS.
    public let isFine: Bool
}

/// Intercepts the volume keys system-wide. Needs the Accessibility permission
/// (System Settings > Privacy & Security > Accessibility), because only an active event tap can swallow the key.
public final class MediaKeyTap {
    /// Return true to swallow the key (macOS then does nothing with it).
    public var handler: ((MediaKeyEvent) -> Bool)?
    /// The tap exists, i.e. macOS allowed it.
    public var isInstalled: Bool { tap != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Only listen while a session runs, so other keys never wait for this app.
    private var wantsEvents = false

    public init() {}

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to System Settings > Privacy > Accessibility.
    public static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: wantsEvents)
        self.tap = tap
        self.source = source
        return true
    }

    public func setEnabled(_ enabled: Bool) {
        wantsEvents = enabled
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit { stop() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, wantsEvents { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
              let parsed = Self.parse(data1: nsEvent.data1, flags: event.flags),
              handler?(parsed) == true
        else { return Unmanaged.passUnretained(event) }
        return nil
    }

    /// Decodes the aux-button payload of an NX_SYSDEFINED event.
    public static func parse(data1: Int, flags: CGEventFlags) -> MediaKeyEvent? {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let state = (keyFlags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        let key: MediaKey
        switch keyCode {
        case 0: key = .volumeUp     // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown   // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute         // NX_KEYTYPE_MUTE
        default: return nil
        }
        return MediaKeyEvent(
            key: key,
            isDown: state == 0xA,
            isRepeat: keyFlags & 0x1 == 1,
            isFine: flags.contains(.maskAlternate) && flags.contains(.maskShift)
        )
    }
}
