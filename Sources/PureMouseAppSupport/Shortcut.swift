import CoreGraphics
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

    /// The config spec for a key press, e.g. key 21 with ⌘⇧ → "shift+cmd+4". Nil for keys the
    /// daemon cannot name.
    static func spec(keyCode: UInt16, modifiers: Modifiers) -> String? {
        guard let key = Keystroke.keyNames[keyCode] else { return nil }
        let names = modifierOrder.filter { modifiers.contains($0.0) }.map(\.name)
        return (names + [key]).joined(separator: "+")
    }

    /// Splits a spec into modifiers and its key's canonical name, with the daemon's own parser;
    /// nil if the daemon would reject it. `fn` is accepted but not shown.
    static func parse(_ spec: String) -> (Modifiers, String)? {
        guard let keystroke = Keystroke(spec), let key = Keystroke.keyNames[keystroke.key] else { return nil }
        let flags: [(CGEventFlags, Modifiers)] = [
            (.maskControl, .control), (.maskAlternate, .option), (.maskShift, .shift), (.maskCommand, .command),
        ]
        var modifiers: Modifiers = []
        for (flag, modifier) in flags where keystroke.modifiers.contains(flag) { modifiers.insert(modifier) }
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
        case "return": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "delete": "⌫"
        case "forwarddelete": "⌦"
        case "escape": "⎋"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        default: key.uppercased()
        }
    }
}

/// Validates a shortcut spec as the daemon will: its parser, then the config decoder.
enum ShortcutCheck {
    static func isValid(_ spec: String) -> Bool {
        guard Shortcut.isValid(spec) else { return false }
        let probe = JSON.encode(["buttons": ["middle": ["keys": spec]]])
        return (try? ConfigCheck.validate(probe)) != nil
    }
}
