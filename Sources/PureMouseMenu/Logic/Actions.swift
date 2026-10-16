import Foundation

/// What a button (or a gesture direction) is bound to, as the config JSON says.
enum ButtonAction: Equatable {
    /// No key: the button works as the mouse does without PureMouse.
    case standard
    case named(String)
    case keys(String)
    case run(String)
    case haptic(String)
    case gesture

    init(json: Any?) {
        switch json {
        case nil: self = .standard
        case let name as String: self = .named(name)
        case let object as [String: Any]:
            if let spec = object["keys"] as? String {
                self = .keys(spec)
            } else if let command = object["run"] as? String {
                self = .run(command)
            } else if let waveform = object["haptic"] as? String {
                self = .haptic(waveform)
            } else if !object.isEmpty, object.keys.allSatisfy(Gesture.directions.contains) {
                self = .gesture
            } else {
                self = .named("?")
            }
        default: self = .named("?")
        }
    }

    /// The label on a button's pop-up.
    var label: String {
        switch self {
        case .standard: "Default"
        case .named(let name): ActionCatalog.label(for: name)
        case .keys(let spec): Shortcut.display(spec) ?? spec
        case .run(let command): command.isEmpty ? "Run Shell Command" : command
        case .haptic(let name): "Haptic: \(name)"
        case .gesture: "Hold and Move"
        }
    }
}

enum Gesture {
    static let directions = ["click", "up", "down", "left", "right"]
    static func label(_ direction: String) -> String {
        switch direction {
        case "click": "Click"
        case "up": "Move up"
        case "down": "Move down"
        case "left": "Move left"
        default: "Move right"
        }
    }
}

/// The named actions, grouped as the action picker shows them.
enum ActionCatalog {
    struct Group {
        let title: String?
        let names: [String]
    }

    static let groups: [Group] = [
        Group(title: "Desktop", names: ["missionControl", "appExpose", "showDesktop", "launchpad"]),
        Group(title: "Spaces and Navigation", names: ["spaceLeft", "spaceRight", "navigateBack", "navigateForward"]),
        Group(title: "Mouse", names: ["toggleScrollMode", "cycleDPI"]),
    ]

    static func label(for name: String) -> String {
        switch name {
        case "none": "Do Nothing"
        case "missionControl": "Mission Control"
        case "appExpose": "App Exposé"
        case "showDesktop": "Show Desktop"
        case "launchpad": launchpadLabel
        case "spaceLeft": "Move Left a Space"
        case "spaceRight": "Move Right a Space"
        case "navigateBack": "Back"
        case "navigateForward": "Forward"
        case "toggleScrollMode": "Switch Wheel Mode"
        case "cycleDPI": "Cycle Pointer Speed"
        default: name
        }
    }

    /// Launchpad became "Apps" in macOS 26.
    static var launchpadLabel: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Apps" : "Launchpad"
    }
}

/// The named buttons the Buttons pane lists, in order, with their control IDs.
enum NamedButton: String, CaseIterable {
    case gesture, back, forward, top, middle, thumbPanel

    var label: String {
        switch self {
        case .gesture: "Gesture button"
        case .back: "Back"
        case .forward: "Forward"
        case .top: "Top button"
        case .middle: "Wheel click"
        case .thumbPanel: "Thumb panel"
        }
    }

    var cid: UInt16 {
        switch self {
        case .middle: 0x0052
        case .back: 0x0053
        case .forward: 0x0056
        case .gesture: 0x00C3
        case .top: 0x00C4
        case .thumbPanel: 0x01A0
        }
    }

    static func config(cid: UInt16) -> String {
        allCases.first { $0.cid == cid }?.rawValue ?? hex(cid)
    }

    static func hex(_ cid: UInt16) -> String { String(format: "0x%04x", cid) }

    /// The control ID a config key names: a button name or a hex ID.
    static func cid(forKey key: String) -> UInt16? {
        if let named = NamedButton(rawValue: key) { return named.cid }
        let hex = key.lowercased().hasPrefix("0x") ? String(key.dropFirst(2)) : key
        return UInt16(hex, radix: 16)
    }
}

/// Which controls the Buttons pane lists under "Other controls".
enum ButtonRows {
    /// Controls without a name: the connected mice's, as hex IDs, plus any the config binds that
    /// they do not have. A hex key for a named control ("0x0053") shows under its name instead.
    static func others(deviceCIDs: [UInt16], configKeys: [String]) -> [String] {
        var seen = Set(NamedButton.allCases.map(\.cid))
        var keys: [String] = []
        for cid in deviceCIDs where seen.insert(cid).inserted { keys.append(NamedButton.hex(cid)) }
        for key in configKeys.sorted() {
            guard let cid = NamedButton.cid(forKey: key), seen.insert(cid).inserted else { continue }
            keys.append(key)
        }
        return keys.sorted()
    }
}
