import Foundation

/// How one login job (the daemon or the menu bar app) stands with the login mechanism.
public enum JobStatus: String, Codable, Sendable {
    /// Not set to start at login.
    case notRegistered
    /// Set to start at login.
    case enabled
    /// Registered, but the user has to approve it first (System Settings › Login Items).
    case requiresApproval
    /// The mechanism has no definition for it, e.g. a build without a menu bar app.
    case notFound
}

/// What `puremouse login-status` prints, as one JSON object: whether each job starts at login,
/// which mechanism holds the answer, and whether `menu off` has hidden the icon. Data only; the
/// daemon's CLI computes it (docs/companion.md, "Login and lifecycle").
public struct LoginStatus: Codable, Equatable, Sendable {
    /// The mechanism: `launchd`.
    public var service: String
    public var daemon: JobStatus
    public var menu: JobStatus
    /// `menu off` is in force: `register` and `start` leave the menu bar app out.
    public var hidden: Bool

    public init(service: String, daemon: JobStatus, menu: JobStatus, hidden: Bool) {
        self.service = service
        self.daemon = daemon
        self.menu = menu
        self.hidden = hidden
    }

    /// PureMouse starts at login.
    public var startsAtLogin: Bool { daemon == .enabled }

    /// One line of JSON with sorted keys.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Parses `login-status` output; nil for anything else.
    public static func parse(_ output: String) -> LoginStatus? {
        try? JSONDecoder().decode(LoginStatus.self, from: Data(output.utf8))
    }
}
