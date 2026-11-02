import AppKit
import PureMouseAppSupport

/// The app that shows Settings: what a pane asks of it beyond the config and the daemon.
@MainActor
public protocol SettingsHost: AnyObject {
    /// "Show in menu bar": whether the menu bar icon is shown.
    var showsStatusItem: Bool { get }
    /// "Show in menu bar" was switched.
    func setMenuBarPreference(_ shown: Bool)
    /// The window has closed; its controller and views go after this returns.
    func settingsDidClose()
    /// Low-battery notifications were turned on: ask macOS for permission now, while the user
    /// is here to answer.
    func requestNotifications() async
    /// Whether macOS shows PureMouse's notifications (nil: not asked yet, or unknown).
    func notificationsAllowed() async -> Bool?
}

/// What a pane may ask of the window around it and of the app hosting Settings.
@MainActor
final class SettingsContext {
    let host: SettingsHost
    weak var tabs: SettingsTabs?

    init(host: SettingsHost) {
        self.host = host
    }

    var window: NSWindow? { tabs?.view.window }

    /// Fits the window to its pane once a change in the pane's height has laid out
    /// (`SettingsTabs.refit`).
    func refit() {
        DispatchQueue.main.async { [weak self] in self?.tabs?.refit() }
    }
}
