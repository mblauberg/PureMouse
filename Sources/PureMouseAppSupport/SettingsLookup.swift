import Foundation

/// Where the menu bar app finds the Settings helper (docs/adr/0009-settings-helper-app.md), in
/// this order: `PUREMOUSE_SETTINGS` (a development override: the app or the bare binary), the
/// helper nested in PureMouse.app, then a `PureMouseSettings` binary beside the menu bar app's own
/// (`swift build` puts them together). Pure, so that each case is tested without a bundle.
public enum SettingsLookup {
    public static let bundleIdentifier = "io.github.mblauberg.puremouse.settings"
    static let appName = "PureMouse Settings.app"
    static let binaryName = "PureMouseSettings"

    public enum Helper: Equatable, Sendable {
        /// Opened with `NSWorkspace`, which keeps one instance per bundle identifier.
        case app(URL)
        /// A development build's bare binary, started with `Process`.
        case binary(URL)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// `PUREMOUSE_SETTINGS` names nothing that can run.
        case overrideMissing(String)
        /// Neither the nested app nor a sibling binary exists.
        case notFound(app: String, binary: String)

        public var description: String {
            switch self {
            case .overrideMissing(let path): "PUREMOUSE_SETTINGS names \(path), which does not exist."
            case .notFound(let app, let binary): "Neither \(app) nor \(binary) exists."
            }
        }
    }

    /// `bundle` and `executable` are the menu bar app's own. `exists` says whether an app is there,
    /// or a binary is executable there.
    public static func find(environment: [String: String], bundle: URL, executable: URL,
                            exists: (URL) -> Bool) -> Result<Helper, Failure> {
        if let path = environment["PUREMOUSE_SETTINGS"] {
            let url = URL(fileURLWithPath: path)
            guard exists(url) else { return .failure(.overrideMissing(url.path)) }
            return .success(url.pathExtension == "app" ? .app(url) : .binary(url))
        }
        // PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app → Contents/Helpers.
        let app = bundle.appending(path: "../../../Helpers/\(appName)").standardizedFileURL
        if exists(app) { return .success(.app(app)) }
        let binary = executable.deletingLastPathComponent().appending(path: binaryName)
        if exists(binary) { return .success(.binary(binary)) }
        return .failure(.notFound(app: app.path, binary: binary.path))
    }

    /// The development overrides the helper inherits, so that it edits the same fixture config
    /// and talks to the same stub daemon as the menu bar app that opened it. Nothing else is
    /// named here; LaunchServices supplies the rest (the opener's, as observed on macOS 27, which is
    /// how the helper gets the menu app's `MallocSpaceEfficient`).
    public static func environment(from environment: [String: String]) -> [String: String] {
        environment.filter { $0.key.hasPrefix("PUREMOUSE_") }
    }
}
