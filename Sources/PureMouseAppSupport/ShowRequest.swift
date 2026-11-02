import Foundation
import PureMouseKit
import notify

/// "Show Settings": the `show-settings` file, stamped with its time and naming the pane to open
/// (empty: the last one shown), plus a doorbell, so a process still starting up (and not yet
/// listening) sees it too. Only a request from the last 5 s counts (docs/companion.md).
public struct ShowRequest: Equatable, Sendable {
    /// The pane asked for; nil opens the last one shown.
    public var pane: SettingsPane?

    static let freshness: TimeInterval = 5

    public static func post(pane: SettingsPane? = nil) {
        write(pane: pane, to: Companion.showSettingsURL)
        notify_post(Companion.showSettingsNotification)
    }

    /// The request posted in the last few seconds, if any; removes the file either way.
    public static func consume() -> ShowRequest? {
        consume(from: Companion.showSettingsURL, now: Date())
    }

    /// Through `SettingsRequest`, under the lock the daemon's writer takes too.
    static func write(pane: SettingsPane?, to file: URL) {
        SettingsRequest.write(pane?.rawValue ?? "", to: file)
    }

    static func consume(from file: URL, now: Date) -> ShowRequest? {
        guard let (date, body) = SettingsRequest.take(from: file), now.timeIntervalSince(date) < freshness else { return nil }
        return ShowRequest(pane: SettingsPane(rawValue: body.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
