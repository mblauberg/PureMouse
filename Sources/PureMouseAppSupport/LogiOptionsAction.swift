import Foundation

/// What the Logi Options+ notice offers (a banner, General's row, the menu). Neither signals a
/// process nor starts anything: Quit asks the app to quit, as choosing Quit in its own menu would,
/// and Open Login Items Settings only opens the pane where the user removes its login item
/// (docs/troubleshooting.md#logi-options).
public enum LogiOptionsAction: Equatable, Sendable, CaseIterable {
    case quit
    case openLoginItems

    public var title: String {
        switch self {
        case .quit: "Quit Logi Options+"
        case .openLoginItems: "Open Login Items Settings"
        }
    }

    /// The pane Open Login Items Settings opens.
    public var url: URL? { self == .openLoginItems ? OpenAtLogin.settingsURL : nil }

    /// Bundle identifier prefixes of Logi Options+'s app, its agent (the login item) and its
    /// updater. Quit asks the running apps that match.
    public static let bundleIdentifierPrefixes = ["com.logi.optionsplus", "com.logi.cp-dev-mgr"]

    public static func isLogiOptions(bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier?.lowercased() else { return false }
        return bundleIdentifierPrefixes.contains { id.hasPrefix($0) }
    }
}

extension Notice {
    /// The notice's own buttons, in order, where they are not a link or a login command.
    public var logiOptionsActions: [LogiOptionsAction] { self == .logiOptions ? LogiOptionsAction.allCases : [] }
}
