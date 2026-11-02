import Foundation

/// A Settings tab. The menu names one to open; the window remembers the last one shown.
public enum SettingsPane: String, CaseIterable, Sendable {
    case general, buttons, scrolling, pointer, apps, about

    /// The pane Settings opens on: the one stored when last shown, else Buttons.
    public static func remembered(_ stored: String?) -> SettingsPane {
        stored.flatMap(SettingsPane.init) ?? .buttons
    }
}

/// The System Settings privacy pane an attention row or a permission row opens.
public enum PrivacyPane: String, Sendable {
    case accessibility = "Privacy_Accessibility"
    case inputMonitoring = "Privacy_ListenEvent"

    public var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
}

/// Pages both apps open. Settings' own are `PureMouseSettingsUI`'s extension.
public enum Links {
    public static let releases = URL(string: "https://github.com/mblauberg/PureMouse/releases")!
}
