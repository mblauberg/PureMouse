import CoreGraphics
import Foundation
import IOKit
import IOKit.hidsystem
import PureMouseKit

/// The keyboard's media keys (volume, mute, brightness), posted as IOHIDSystem auxiliary control
/// buttons the way the keys themselves arrive, so the system shows its usual overlay. IOKit only:
/// the `NSEvent` route other apps use needs AppKit. Recipe from LinearMouse (KeyKit,
/// `postSystemDefinedKey`).
@MainActor
enum AuxKey {
    /// `NX_KEYTYPE_*` from `ev_keymap.h`.
    static let soundUp = NX_KEYTYPE_SOUND_UP, soundDown = NX_KEYTYPE_SOUND_DOWN, mute = NX_KEYTYPE_MUTE
    static let brightnessUp = NX_KEYTYPE_BRIGHTNESS_UP, brightnessDown = NX_KEYTYPE_BRIGHTNESS_DOWN

    private typealias PostEvent = @convention(c) (io_connect_t, UInt32, IOGPoint, UnsafePointer<NXEventData>?,
                                                  UInt32, IOOptionBits, IOOptionBits) -> kern_return_t
    /// IOHIDPostEvent is deprecated (since macOS 11) without a replacement for auxiliary keys,
    /// so it is looked up at run time rather than called by name.
    private static let postEvent: PostEvent? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDPostEvent") else {  // RTLD_DEFAULT
            Log.error("IOHIDPostEvent unavailable; media key actions do nothing")
            return nil
        }
        return unsafeBitCast(symbol, to: PostEvent.self)
    }()
    /// Opened on first use and kept: an idle connection costs nothing.
    private static var connection: io_connect_t = 0

    /// Presses and releases `key`. Modifiers held on the keyboard ride along, so Shift+Option
    /// gives the system's quarter steps.
    static func press(_ key: Int32) {
        guard let postEvent, let handle = open() else { return }
        let flags = UInt32(truncatingIfNeeded: CGEventSource.flagsState(.combinedSessionState).rawValue)
        for down in [true, false] {
            var event = NXEventData()
            event.compound.subType = Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS)
            event.compound.misc.L.0 = key << 16 | (down ? NX_KEYDOWN : NX_KEYUP) << 8
            let result = postEvent(handle, UInt32(NX_SYSDEFINED), IOGPoint(x: 0, y: 0), &event,
                                   UInt32(kNXEventDataVersion), flags, IOOptionBits(kIOHIDSetGlobalEventFlags))
            if result != KERN_SUCCESS {
                Log.error("posting media key \(key) failed: \(result)")
                IOServiceClose(handle)
                connection = 0  // reopened next time
                return
            }
        }
    }

    private static func open() -> io_connect_t? {
        if connection != 0 { return connection }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var handle: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &handle)
        guard result == KERN_SUCCESS else {
            Log.error("opening IOHIDSystem failed: \(result)")
            return nil
        }
        connection = handle
        return handle
    }
}

/// The user's own shortcut for a system hot key such as "Move left a space", read with the
/// private `CGSGetSymbolicHotKeyValue` (as LinearMouse and Mac Mouse Fix do). Read only: a
/// disabled or cleared shortcut gives nil rather than being switched on.
enum SymbolicHotKey {
    static let spaceLeft: UInt32 = 79, spaceRight: UInt32 = 81

    private typealias GetValue = @convention(c) (UInt32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>,
                                                 UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabled = @convention(c) (UInt32) -> Bool
    private static let functions: (GetValue, IsEnabled)? = {
        // Exported by SkyLight through CoreGraphics, which PureMouse links.
        let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let get = dlsym(handle, "CGSGetSymbolicHotKeyValue"),
              let enabled = dlsym(handle, "CGSIsSymbolicHotKeyEnabled") else {
            Log.error("CGSGetSymbolicHotKeyValue unavailable; using ctrl+arrow for Spaces")
            return nil
        }
        return (unsafeBitCast(get, to: GetValue.self), unsafeBitCast(enabled, to: IsEnabled.self))
    }()

    static func keystroke(_ hotKey: UInt32) -> Keystroke? {
        guard let (get, isEnabled) = functions, isEnabled(hotKey) else { return nil }
        var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt32 = 0
        guard get(hotKey, &character, &keyCode, &modifiers) == 0 else { return nil }
        return keystroke(character: character, keyCode: keyCode, modifiers: modifiers)
    }

    /// A cleared shortcut reports key code 0xFFFF, one never assigned 0 with no character;
    /// posting either would type a stray key (0 is A).
    static func keystroke(character: UInt16, keyCode: UInt16, modifiers: UInt32) -> Keystroke? {
        guard keyCode != 0xFFFF, keyCode != 0 || character != 0xFFFF else { return nil }
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        return Keystroke(key: CGKeyCode(keyCode), modifiers: CGEventFlags(rawValue: UInt64(modifiers)).intersection(mask))
    }
}
