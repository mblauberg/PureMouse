import CoreGraphics

/// A key plus modifiers, parsed from specs like `"cmd+shift+4"`, `"ctrl+left"` or `"f11"`.
/// Key names follow the US ANSI layout.
struct Keystroke: Equatable {
    let key: CGKeyCode
    let modifiers: CGEventFlags

    init(key: CGKeyCode, modifiers: CGEventFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(_ spec: String) {
        var modifiers: CGEventFlags = []
        var key: CGKeyCode?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            if let modifier = Self.modifierNames[part] {
                modifiers.insert(modifier)
            } else if key == nil, let code = Self.keyCodes[part] {
                key = code
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    func post() {
        // Arrow and function keys carry these flags when typed on a real keyboard; system
        // shortcuts such as ctrl+arrow (switch Space) only match when they are present.
        var flags = modifiers
        if Self.arrowKeys.contains(key) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        if Self.functionKeys.contains(key) { flags.insert(.maskSecondaryFn) }

        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private static let modifierNames: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "ctrl": .maskControl, "control": .maskControl,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "fn": .maskSecondaryFn,
    ]

    private static let arrowKeys: Set<CGKeyCode> = [123, 124, 125, 126]
    /// F1–F12 in order.
    private static let fKeyCodes: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    private static let functionKeys = Set(fKeyCodes)

    private static let keyCodes: [String: CGKeyCode] = {
        var codes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
            "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44,
            ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        for (i, code) in fKeyCodes.enumerated() { codes["f\(i + 1)"] = code }
        return codes
    }()
}
