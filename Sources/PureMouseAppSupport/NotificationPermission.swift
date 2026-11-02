import Foundation
import PureMouseKit

/// macOS asks per app whether it may post notifications, and the menu bar app is the one that
/// posts them, so only it can ask or read the answer. It records a denial in its own defaults
/// domain when it learns one, and the Settings helper reads it there for the General pane's hint.
public enum NotificationPermission {
    static let deniedKey = "NotificationsDenied"

    /// The menu bar app's defaults, as another app on the same account sees them.
    public static var menuDefaults: UserDefaults? { UserDefaults(suiteName: Companion.menuLabel) }

    /// The menu bar app, on learning the answer: denied, or anything else (allowed, not asked yet).
    public static func record(denied: Bool, in defaults: UserDefaults) {
        if denied {
            defaults.set(true, forKey: deniedKey)
        } else {
            defaults.removeObject(forKey: deniedKey)
        }
    }

    /// Whether the menu bar app last learned that its notifications are off in System Settings.
    public static func denied(in defaults: UserDefaults?) -> Bool {
        defaults?.bool(forKey: deniedKey) ?? false
    }

    /// The menu bar app asks for permission when low-battery notifications go from off to on in the
    /// config, while the user who turned them on is there to answer.
    public static func shouldRequest(wasOn: Bool, isOn: Bool) -> Bool {
        isOn && !wasOn
    }
}
