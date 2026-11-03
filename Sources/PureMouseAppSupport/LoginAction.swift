import Foundation
import PureMouseKit

/// What a control in General's Startup section asks for, and the CLI command that does it
/// (docs/companion.md, "Login and lifecycle"). "Opens at login" and "is running now" are separate
/// axes, so the two controls never share a command: switching login off does not stop PureMouse,
/// and Start does not change whether it opens at login. Settings pauses and resumes PureMouse through
/// the daemon's control file (`AppModel.setPaused`), not through `start`.
public enum LoginAction: Equatable, Sendable {
    /// The Open at login switch moved.
    case openAtLogin(Bool)
    /// Start, offered while PureMouse is off. Settings has no Stop (Quit PureMouse is the menu bar
    /// app's, `Lifecycle.Command.stop`).
    case start

    public var command: Lifecycle.Command {
        switch self {
        case .openAtLogin(let on): on ? .loginOn : .loginOff
        case .start: .start
        }
    }
}

/// The Open at login row, from what `puremouse login-status` said (nil: it could not be asked).
public struct OpenAtLogin: Equatable, Sendable {
    public var status: LoginStatus?

    public init(_ status: LoginStatus?) { self.status = status }

    /// The switch: on once the daemon is registered, including while macOS waits for the user to
    /// approve it, so the switch can still be turned off.
    public var isOn: Bool { status.map { $0.daemon == .enabled || $0.daemon == .requiresApproval } ?? false }

    /// A registered job that macOS will not start until the user approves it.
    public var needsApproval: Bool {
        status.map { $0.daemon == .requiresApproval || $0.menu == .requiresApproval } ?? false
    }

    /// System Settings › General › Login Items, where the user approves.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}
