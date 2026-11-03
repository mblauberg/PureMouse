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
        case .openLoginItems: "Open Login Items Settings…"
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
    /// The notice's own button, where it is not a link or a login command.
    public var logiOptionsActions: [LogiOptionsAction] { self == .logiOptions ? [.quit] : [] }

    /// The link-style button under the notice's message.
    public var logiOptionsLink: LogiOptionsAction? { self == .logiOptions ? .openLoginItems : nil }
}

/// Holds at most one observation per key (a process id), so asking twice does not pile them up,
/// and lets one go once its process has quit. The AppKit side keeps the observations in it.
public struct OneObservationEach<Key: Hashable, Observation> {
    private var held: [Key: Observation] = [:]

    public init() {}

    public var count: Int { held.count }

    /// Makes and keeps an observation for `key` unless one is held; whether it did.
    @discardableResult
    public mutating func start(_ key: Key, make: () -> Observation) -> Bool {
        guard held[key] == nil else { return false }
        held[key] = make()
        return true
    }

    public mutating func finish(_ key: Key) { held[key] = nil }
}
