import Foundation
import PureMouseKit

/// Keyboard shortcut specs as the config stores them ("cmd+shift+4": US ANSI key names, as the
/// daemon's `Keystroke` parses them), and their display form ("⇧⌘4").
enum Shortcut {
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    /// In the order macOS displays them.
    private static let modifierOrder: [(Modifiers, name: String, glyph: String)] = [
        (.control, "ctrl", "⌃"), (.option, "opt", "⌥"), (.shift, "shift", "⇧"), (.command, "cmd", "⌘"),
    ]

    private static let modifierAliases: [String: Modifiers] = [
        "cmd": .command, "command": .command, "shift": .shift, "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
    ]

    /// Virtual key code → canonical config name. Mirrors the daemon's `Keystroke` table.
    static let keyNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
            34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/",
            47: ".", 50: "`",
            36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape", 117: "forwarddelete",
            115: "home", 119: "end", 116: "pageup", 121: "pagedown",
            123: "left", 124: "right", 125: "down", 126: "up",
        ]
        for (i, code) in fKeyCodes.enumerated() { names[code] = "f\(i + 1)" }
        return names
    }()

    static let fKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// Every key name the daemon accepts, aliases included.
    private static let acceptedKeys: Set<String> = Set(keyNames.values).union(["enter", "backspace", "esc"])

    /// The config spec for a key press, e.g. key 21 with ⌘⇧ → "shift+cmd+4". Nil for keys the
    /// daemon cannot name.
    static func spec(keyCode: UInt16, modifiers: Modifiers) -> String? {
        guard let key = keyNames[keyCode] else { return nil }
        let names = modifierOrder.filter { modifiers.contains($0.0) }.map(\.name)
        return (names + [key]).joined(separator: "+")
    }

    /// Splits a spec into modifiers and its single key, or nil if the daemon would reject it.
    static func parse(_ spec: String) -> (Modifiers, String)? {
        var modifiers: Modifiers = []
        var key: String?
        let parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for part in parts {
            if let modifier = modifierAliases[part] {
                modifiers.insert(modifier)
            } else if part == "fn" {
                continue
            } else if key == nil, acceptedKeys.contains(part) {
                key = part
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        return (modifiers, key)
    }

    static func isValid(_ spec: String) -> Bool { parse(spec) != nil }

    /// "cmd+shift+4" → "⇧⌘4"; nil if the spec does not parse.
    static func display(_ spec: String) -> String? {
        guard let (modifiers, key) = parse(spec) else { return nil }
        let glyphs = modifierOrder.filter { modifiers.contains($0.0) }.map(\.glyph).joined()
        return glyphs + keyGlyph(key)
    }

    /// Spoken form for VoiceOver: "Shift Command 4".
    static func spoken(_ spec: String) -> String {
        guard let (modifiers, key) = parse(spec) else { return spec }
        let words = [(Modifiers.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
            .filter { modifiers.contains($0.0) }.map(\.1)
        return (words + [key.count == 1 ? key.uppercased() : key.capitalized]).joined(separator: " ")
    }

    private static func keyGlyph(_ key: String) -> String {
        switch key {
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "return", "enter": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "delete", "backspace": "⌫"
        case "forwarddelete": "⌦"
        case "escape", "esc": "⎋"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        default: key.uppercased()
        }
    }
}

/// Validates a shortcut spec as the daemon will: our key table, then the config decoder.
enum ShortcutCheck {
    static func isValid(_ spec: String) -> Bool {
        guard Shortcut.isValid(spec) else { return false }
        let probe = JSON.encode(["buttons": ["middle": ["keys": spec]]])
        return (try? ConfigCheck.validate(probe)) != nil
    }
}
