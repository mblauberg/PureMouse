import Foundation

/// Something a button or gesture direction does. In config JSON an action is either a name
/// (`"missionControl"`) or an object: `{"keys": "cmd+shift+4"}` or `{"run": "open -a Safari"}`.
/// Data only: the daemon performs actions (`SystemActions`).
public enum Action: Equatable, Decodable, Sendable {
    case none
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight
    case navigateBack
    case navigateForward
    /// Flip the scroll wheel between ratchet and free-spin. Handled by the device session.
    case toggleScrollMode
    case keys(Keystroke)
    case run(String)

    /// Every action that has a name, by its config name.
    public static let named: [String: Action] = [
        "none": .none, "missionControl": .missionControl, "appExpose": .appExpose,
        "showDesktop": .showDesktop, "launchpad": .launchpad, "spaceLeft": .spaceLeft,
        "spaceRight": .spaceRight, "navigateBack": .navigateBack, "navigateForward": .navigateForward,
        "toggleScrollMode": .toggleScrollMode,
    ]

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard let action = Self.named[name] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "unknown action '\(name)'; known: \(Self.named.keys.sorted().joined(separator: ", "))"))
            }
            self = action
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        if let spec = try c.decodeIfPresent(String.self, forKey: AnyKey("keys")) {
            guard let keystroke = Keystroke(spec) else {
                throw DecodingError.dataCorruptedError(forKey: AnyKey("keys"), in: c,
                                                       debugDescription: "cannot parse keystroke '\(spec)'")
            }
            self = .keys(keystroke)
        } else if let command = try c.decodeIfPresent(String.self, forKey: AnyKey("run")) {
            self = .run(command)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "expected an action name, {\"keys\": ...} or {\"run\": ...}"))
        }
    }
}
