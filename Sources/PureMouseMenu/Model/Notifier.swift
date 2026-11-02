import Foundation
import PureMouseAppSupport
import UserNotifications

/// Posts the low-battery notification, and takes it down when it stops being true. Permission is asked for lazily: when the user turns the
/// setting on in Settings (`AppController` sees the config change), or the first time a
/// notification is due. Each answer it learns is recorded for Settings' hint
/// (`NotificationPermission`). Without a bundle (a development run outside an app) it does
/// nothing: `UNUserNotificationCenter` would trap.
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

    /// Asks once; a denial stays denied and shows no prompt again. Returns whether we may post.
    @discardableResult
    static func requestIfNeeded() async -> Bool {
        guard let center else { return false }
        center.delegate = delegate
        switch await status(center) {
        case .authorized, .provisional: return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            _ = await status(center)
            return granted
        default: return false
        }
    }

    /// Reads the answer without asking (at launch, and as Settings opens, since it may have been
    /// changed in System Settings meanwhile).
    static func refresh() async {
        guard let center else { return }
        _ = await status(center)
    }

    private static func status(_ center: UNUserNotificationCenter) async -> UNAuthorizationStatus {
        let status = await center.notificationSettings().authorizationStatus
        NotificationPermission.record(denied: status == .denied, in: .standard)
        return status
    }

    /// Takes delivered notifications down (the mouse charged, or a deeper warning replaced them).
    static func removeDelivered(ids: [String]) {
        center?.removeDeliveredNotifications(withIdentifiers: ids)
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
