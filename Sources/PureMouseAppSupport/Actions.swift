import Foundation
import PureMouseKit

/// What a button (or a gesture direction) is bound to, as the config JSON says.
public enum ButtonAction: Equatable, Sendable {
    /// No key: the button works as the mouse does without PureMouse; on a mouse or in an app, the
    /// wider scope's binding applies.
    case standard
    /// The key `"default"` (`Config.Binding.nativeValue`) on a mouse or in an app: the button works
    /// as the mouse does without PureMouse there, whatever the wider scope binds. At the top
    /// level it is the same as `.standard`, and is never written.
    case mouseDefault
    case named(String)
    case keys(String)
    case run(String)
    case haptic(String)
    case gesture

    public init(json: Any?) {
        switch json {
        case nil: self = .standard
        case let name as String: self = name == Config.Binding.nativeValue ? .mouseDefault : .named(name)
        case let object as [String: Any]:
            // A table first, as Kit reads it (`Config.Binding.decode`).
            if Gesture.isTable(object) {
                self = .gesture
            } else if let spec = object["keys"] as? String {
                self = .keys(spec)
            } else if let command = object["run"] as? String {
                self = .run(command)
            } else if let waveform = object["haptic"] as? String {
                self = .haptic(waveform)
            } else if object["precisePointer"] != nil {
                // A speed of its own is config-only: the row shows the action.
                self = .named("precisePointer")
            } else {
                self = .named("?")
            }
        default: self = .named("?")
        }
    }

    /// Whether the action lasts while the button is held, so it owns the button on its Click row
    /// (`Action.isWhileHeld`): Precise Pointer.
    public var isWhileHeld: Bool {
        if case .named(let name) = self { return Action.named[name]?.isWhileHeld ?? false }
        return false
    }

    /// The label on a button's pop-up.
    public var label: String {
        switch self {
        case .standard, .mouseDefault: "Mouse Default"
        case .named(let name): ActionCatalog.label(for: name)
        case .keys(let spec): Shortcut.display(spec) ?? spec
        case .run(let command): command.isEmpty ? "Run Command" : command
        case .haptic(let name): "Haptic: \(ActionCatalog.hapticLabel(for: name))"
        case .gesture: "Hold and Move"
        }
    }

    /// The label as VoiceOver says it: a shortcut in words ("Shift Command 4"), not glyphs.
    public var spokenLabel: String {
        if case .keys(let spec) = self { return Shortcut.spoken(spec) }
        return label
    }
}

/// A button's trigger table (ADR 24): `click`, `doubleClick`, and one hold form, `hold` or Hold and
/// Move's four directions. Settings reads and lays tables as Kit decodes them
/// (`Config.Binding.Gesture`).
public enum Gesture {
    /// Every key of a table, in the order its rows show.
    public static let triggers = Config.Binding.Gesture.triggers
    /// Hold and Move's directions: the hold form that is not `hold`.
    public static let directions = Config.Binding.Gesture.directions

    /// Hold and Move's standard directions, seeded when it is chosen (#146).
    public static let standardDirections: [String: String] = [
        "up": "missionControl", "down": "appExpose", "left": "spaceLeft", "right": "spaceRight",
    ]

    /// Whether Kit reads `object` as a table: it names a trigger, or a key kept for one (`scroll`).
    public static func isTable(_ object: [String: Any]) -> Bool {
        object.keys.contains { triggers.contains($0) || Config.Binding.Gesture.reserved.contains($0) }
    }

    /// `top` over a wider table `base`, trigger by trigger, as Kit decodes a scope's table over a
    /// wider one: a `null` leaves `base`'s, and a hold form replaces the other (`hold` clears the
    /// directions, a direction clears `hold`).
    public static func merge(_ top: [String: Any], over base: [String: Any]) -> [String: Any] {
        var out = base
        if top["hold"] != nil { for key in directions { out[key] = nil } }
        if directions.contains(where: { top[$0] != nil }) { out["hold"] = nil }
        for (key, value) in top where !(value is NSNull && out[key] != nil) { out[key] = value }
        return out
    }

    public static func label(_ trigger: String) -> String {
        switch trigger {
        case "click": "Click"
        case "doubleClick": "Double-click"
        case "hold": "Hold"
        case "up": "Move up"
        case "down": "Move down"
        case "left": "Move left"
        default: "Move right"
        }
    }
}

/// The named actions, grouped as the action picker shows them.
public enum ActionCatalog {
    public struct Group: Sendable {
        public let title: String?
        public let names: [String]
    }

    public static let groups: [Group] = [
        Group(title: "Desktop", names: ["missionControl", "appExpose", "showDesktop", "launchpad"]),
        Group(title: "Spaces and Navigation", names: ["spaceLeft", "spaceRight", "navigateBack", "navigateForward"]),
        Group(title: "Mouse", names: ["middleClick", "precisePointer", "dragLock", "toggleScrollMode", "cycleDPI"]),
        Group(title: "Media", names: ["playPause", "nextTrack", "previousTrack", "volumeUp", "volumeDown", "mute"]),
        Group(title: "Display", names: ["brightnessUp", "brightnessDown"]),
        Group(title: "Tabs and Zoom", names: ["nextTab", "previousTab", "zoomIn", "zoomOut"]),
    ]

    public static func label(for name: String) -> String {
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
        case "volumeUp": "Volume Up"
        case "volumeDown": "Volume Down"
        case "mute": "Mute"
        case "playPause": "Play/Pause"
        case "nextTrack": "Next Track"
        case "previousTrack": "Previous Track"
        case "middleClick": "Middle Click"
        case "precisePointer": "Precise Pointer"
        case "dragLock": "Drag Lock"
        case "brightnessUp": "Brightness Up"
        case "brightnessDown": "Brightness Down"
        case "nextTab": "Next Tab"
        case "previousTab": "Previous Tab"
        case "zoomIn": "Zoom In"
        case "zoomOut": "Zoom Out"
        default: name
        }
    }

    /// The SF Symbol (available on macOS 14) beside a named action in the picker.
    public static func symbol(for name: String) -> String? {
        switch name {
        case "none": "nosign"
        case "missionControl": "rectangle.3.group"
        case "appExpose": "rectangle.stack"
        case "showDesktop": "menubar.dock.rectangle"
        case "launchpad": "square.grid.3x3"
        case "spaceLeft": "arrow.left.square"
        case "spaceRight": "arrow.right.square"
        case "navigateBack": "chevron.backward"
        case "navigateForward": "chevron.forward"
        case "toggleScrollMode": "arrow.triangle.2.circlepath"
        case "cycleDPI": "cursorarrow.motionlines"
        case "volumeUp": "speaker.wave.3"
        case "volumeDown": "speaker.wave.1"
        case "mute": "speaker.slash"
        case "playPause": "playpause"
        case "nextTrack": "forward"
        case "previousTrack": "backward"
        case "middleClick": "cursorarrow.click"
        case "precisePointer": "scope"
        case "dragLock": "hand.raised"
        case "brightnessUp": "sun.max"
        case "brightnessDown": "sun.min"
        case "nextTab": "arrow.right.to.line"
        case "previousTab": "arrow.left.to.line"
        case "zoomIn": "plus.magnifyingglass"
        case "zoomOut": "minus.magnifyingglass"
        default: nil
        }
    }

    /// The line under an action in the picker, for those whose name alone does not say what they do.
    public static func caption(for name: String) -> String? {
        switch name {
        case "precisePointer": "Slows the pointer while you hold the button."
        case "dragLock": "Click to start dragging, click again to let go."
        default: nil
        }
    }

    /// The haptic group's title: only the MX Master 4 has the motor.
    public static let hapticGroup = "Haptic Feedback (MX Master 4)"

    /// Kit's waveform names, in its order.
    public static var hapticNames: [String] { HapticWaveform.allCases.map(\.rawValue) }

    /// A waveform's config name in words: "happyAlert" reads "Happy Alert".
    public static func hapticLabel(for name: String) -> String {
        if name == "startEndBreathingSignal" { return "Breathing Start and End" }
        var words = ""
        for character in name {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(words.isEmpty ? Character(character.uppercased()) : character)
        }
        return words
    }

    /// Launchpad became "Apps" in macOS 26.
    static var launchpadLabel: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Apps" : "Launchpad"
    }
}

/// The named buttons the Buttons pane lists, with their control IDs. The order is the rows' order
/// (and the Apps sheet's): the side buttons first, then the wheel and the top of the mouse, then the
/// thumb's (`DeviceCard` draws them where they are).
public enum NamedButton: String, CaseIterable, Sendable {
    case back, forward, middle, top, gesture, thumbPanel

    public var label: String {
        switch self {
        case .gesture: "Gesture button"
        case .back: "Back"
        case .forward: "Forward"
        case .top: "Top button"
        case .middle: "Wheel click"
        case .thumbPanel: "Thumb panel"
        }
    }

    public var cid: UInt16 {
        switch self {
        case .middle: 0x0052
        case .back: 0x0053
        case .forward: 0x0056
        case .gesture: 0x00C3
        case .top: 0x00C4
        case .thumbPanel: 0x01A0
        }
    }

    /// Listed when no mouse has reported its controls. The thumb panel is on the MX Master 4
    /// only, so it shows when a mouse has it or the config binds it.
    var listedByDefault: Bool { self != .thumbPanel }

    static func config(cid: UInt16) -> String {
        allCases.first { $0.cid == cid }?.rawValue ?? hex(cid)
    }

    static func hex(_ cid: UInt16) -> String { String(format: "0x%04x", cid) }

    /// The control ID a config key names: a button name or a hex ID.
    public static func cid(forKey key: String) -> UInt16? {
        if let named = NamedButton(rawValue: key) { return named.cid }
        let hex = key.lowercased().hasPrefix("0x") ? String(key.dropFirst(2)) : key
        return UInt16(hex, radix: 16)
    }
}

/// Which controls the Buttons and Apps panes list.
public enum ButtonRows {
    /// The named buttons: the connected mice's (`nil`: none has reported, so those listed by
    /// default), plus any the config binds.
    public static func named(deviceCIDs: Set<UInt16>?, configKeys: [String]) -> [NamedButton] {
        let bound = Set(configKeys.compactMap(NamedButton.cid(forKey:)))
        return NamedButton.allCases.filter { button in
            bound.contains(button.cid) || deviceCIDs.map { $0.contains(button.cid) } ?? button.listedByDefault
        }
    }


    /// The controls that are not a named button: those the connected mice report that Kit has a
    /// name for ("DPI button"), plus any the config binds, whether or not a mouse has them. A
    /// control with no name is no row until the config binds it: it is not a button anyone can
    /// find by its ID. A hex key for a named control ("0x0053") shows under its name instead.
    public static func others(deviceCIDs: [UInt16], configKeys: [String]) -> [String] {
        var seen = Set(NamedButton.allCases.map(\.cid))
        var keys: [String] = []
        for cid in deviceCIDs where ControlNames.name(cid) != nil && seen.insert(cid).inserted { keys.append(NamedButton.hex(cid)) }
        for key in configKeys.sorted() {
            guard let cid = NamedButton.cid(forKey: key), seen.insert(cid).inserted else { continue }
            keys.append(key)
        }
        return keys.sorted()
    }
}
