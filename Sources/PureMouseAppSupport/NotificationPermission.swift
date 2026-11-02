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

    /// Calls `changed` with the menu bar app's answer each time it records one, for as long as it is
    /// kept. Key-value observing on the domain hears another process's writes;
    /// `UserDefaults.didChangeNotification` does not.
    public final class Watch: NSObject {
        private let defaults: UserDefaults
        private let changed: @MainActor (Bool) -> Void

        public init?(_ defaults: UserDefaults?, changed: @escaping @MainActor (Bool) -> Void) {
            guard let defaults else { return nil }
            self.defaults = defaults
            self.changed = changed
            super.init()
            defaults.addObserver(self, forKeyPath: deniedKey, context: nil)
        }

        deinit { defaults.removeObserver(self, forKeyPath: deniedKey) }

        override public func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                          change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            let denied = NotificationPermission.denied(in: defaults)
            Task { @MainActor [changed] in changed(denied) }
        }
    }

    /// The menu bar app asks for permission when low-battery notifications go from off to on in the
    /// config, while the user who turned them on is there to answer.
    public static func shouldRequest(wasOn: Bool, isOn: Bool) -> Bool {
        isOn && !wasOn
    }
}
