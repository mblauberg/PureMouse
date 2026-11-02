import Foundation
import PureMouseAppSupport
import UserNotifications

/// The notification centre as `NotificationDelivery` uses it, so a test can hold its answers open.
@MainActor
protocol NotificationCentre: AnyObject {
    /// The permission as it stands now, without asking.
    func authorization() async -> UNAuthorizationStatus
    /// Asks the user; whether they allowed it.
    func requestAuthorization() async -> Bool
    func add(id: String, title: String, body: String) async
    func removeDelivered(ids: [String])
}

/// Posts the low-battery notification, and takes it down when it stops being true. Permission is
/// asked for lazily: when the user turns the setting on in Settings (`AppController` sees the
/// config change), or the first time a notification is due. A post waits for that answer, and a
/// withdrawal of its id meanwhile (the mouse charged, or the setting went off) cancels it, so a
/// warning that stopped being true never appears late.
@MainActor
final class NotificationDelivery {
    private let centre: NotificationCentre?
    /// The latest post of each id; withdrawing the id removes it, and posting it again replaces it.
    /// It stays after the post completes, so an older post finishing late can tell a newer one
    /// owns the id from a withdrawal.
    private var tickets: [String: Int] = [:]
    private var lastTicket = 0

    init(centre: NotificationCentre?) { self.centre = centre }

    /// Asks once; a denial stays denied and shows no prompt again. Returns whether we may post.
    @discardableResult
    func requestIfNeeded() async -> Bool {
        guard let centre else { return false }
        switch await centre.authorization() {
        case .authorized, .provisional: return true
        case .notDetermined:
            let granted = await centre.requestAuthorization()
            _ = await centre.authorization()
            return granted
        default: return false
        }
    }

    /// Reads the answer without asking (at launch, and as Settings opens, since it may have been
    /// changed in System Settings meanwhile).
    func refresh() async { _ = await centre?.authorization() }

    @discardableResult
    func post(id: String, title: String, body: String) -> Task<Void, Never> {
        lastTicket += 1
        let ticket = lastTicket
        tickets[id] = ticket
        return Task {
            guard await requestIfNeeded(), let centre, tickets[id] == ticket else { return }
            await centre.add(id: id, title: title, body: body)
            // Withdrawn while it was being added, and not posted again since: it is on screen now,
            // so take it down. A newer post owns the id; it or a later withdrawal handles it.
            if tickets[id] == nil { centre.removeDelivered(ids: [id]) }
        }
    }

    /// Takes delivered notifications down, and cancels any still waiting to be delivered.
    func removeDelivered(ids: [String]) {
        for id in ids { tickets[id] = nil }
        centre?.removeDelivered(ids: ids)
    }
}

@MainActor
enum Notifier {
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // An accessory app counts as foreground; show the banner anyway.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
            async -> UNNotificationPresentationOptions { [.banner, .list] }
    }

    /// The system's centre. Without a bundle (a development run outside an app) there is none:
    /// `UNUserNotificationCenter` would trap.
    private final class SystemCentre: NotificationCentre {
        private let center = UNUserNotificationCenter.current()
        private let delegate = Delegate()

        init() { center.delegate = delegate }

        func authorization() async -> UNAuthorizationStatus {
            let status = await center.notificationSettings().authorizationStatus
            NotificationPermission.record(denied: status == .denied, in: .standard)
            return status
        }

        func requestAuthorization() async -> Bool {
            (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }

        func add(id: String, title: String, body: String) async {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }

        func removeDelivered(ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    private static let delivery = NotificationDelivery(
        centre: Bundle.main.bundleIdentifier == nil ? nil : SystemCentre())

    @discardableResult
    static func requestIfNeeded() async -> Bool { await delivery.requestIfNeeded() }
    static func refresh() async { await delivery.refresh() }
    static func post(id: String, title: String, body: String) { delivery.post(id: id, title: title, body: body) }
    static func removeDelivered(ids: [String]) { delivery.removeDelivered(ids: ids) }
}
