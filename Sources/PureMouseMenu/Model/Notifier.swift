import Foundation
import UserNotifications

/// Posts the low-battery notification. Permission is asked for lazily: when the user turns the
/// setting on, or the first time a notification is due. Without a bundle (a development run
/// outside an app) it does nothing: `UNUserNotificationCenter` would trap.
@MainActor
enum Notifier {
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // An accessory app counts as foreground; show the banner anyway.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
            async -> UNNotificationPresentationOptions { [.banner, .list] }
    }
    private static let delegate = Delegate()

    /// Whether macOS will show our notifications (nil: not asked yet, or no bundle).
    static func isAllowed() async -> Bool? {
        guard let center else { return nil }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return nil
        }
    }

    /// Asks once; a denial stays denied and shows no prompt again. Returns whether we may post.
    @discardableResult
    static func requestIfNeeded() async -> Bool {
        guard let center else { return false }
        center.delegate = delegate
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    static func post(id: String, title: String, body: String) {
        Task {
            guard await requestIfNeeded(), let center else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
