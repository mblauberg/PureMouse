import CoreGraphics
import IOKit.hid

/// The privacy permissions PureMouse needs. macOS caches the answers for the life of a process, so
/// a grant only takes effect in a new one (see `Daemon.restartWhenGranted`).
struct Permissions: OptionSet {
    let rawValue: Int32
    /// Post scroll, key and swipe events. Without it the wheels stay native.
    static let accessibility = Permissions(rawValue: 1)
    /// Read HID++ reports over Bluetooth. The Bolt receiver works without it.
    static let inputMonitoring = Permissions(rawValue: 2)
    static let all: Permissions = [.accessibility, .inputMonitoring]

    static var current: Permissions {
        var granted: Permissions = []
        if CGPreflightPostEventAccess() { granted.insert(.accessibility) }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { granted.insert(.inputMonitoring) }
        return granted
    }

    /// The permissions PureMouse needs now: Accessibility when it posts events (for a binding, or
    /// for wheels it takes over), Input Monitoring for a Bluetooth mouse or when opening HID
    /// devices failed (macOS refuses the open without it).
    static func needed(postsEvents: Bool, bluetooth: Bool, hidOpenFailed: Bool) -> Permissions {
        var needed: Permissions = []
        if postsEvents { needed.insert(.accessibility) }
        if bluetooth || hidOpenFailed { needed.insert(.inputMonitoring) }
        return needed
    }

    /// Shows the system prompt for each missing permission. Each prompt appears once; later
    /// requests are no-ops until the user acts in System Settings.
    static func requestMissing(_ granted: Permissions) {
        if !granted.contains(.inputMonitoring) {
            Log.error("Input Monitoring not granted; requesting")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if !granted.contains(.accessibility) {
            Log.error("Accessibility (post events) not granted; requesting")
            CGRequestPostEventAccess()
        }
    }
}
