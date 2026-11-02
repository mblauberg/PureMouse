import Foundation

/// A Settings tab. The menu names one to open; the window remembers the last one shown.
public enum SettingsPane: String, CaseIterable, Sendable {
    case general, buttons, scrolling, pointer, apps, about

    public var title: String {
        switch self {
        case .general: "General"
        case .buttons: "Buttons"
        case .scrolling: "Scrolling"
        case .pointer: "Pointer"
        case .apps: "Apps"
        case .about: "About"
        }
    }

    /// SF Symbols available on macOS 14.
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .buttons: "computermouse"
        case .scrolling: "arrow.up.and.down"
        case .pointer: "cursorarrow"
        case .apps: "square.grid.2x2"
        case .about: "info.circle"
        }
    }

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

public enum Links {
    public static let repository = URL(string: "https://github.com/mblauberg/PureMouse")!
    public static let releases = URL(string: "https://github.com/mblauberg/PureMouse/releases")!
    public static let licence = URL(string: "https://github.com/mblauberg/PureMouse/blob/main/LICENSE")!
    public static let logiOptions = URL(string: "https://github.com/mblauberg/PureMouse/blob/main/docs/troubleshooting.md#logi-options")!
}
