import Foundation

/// Config settings with meaning beyond one key.
extension ConfigTree {
    /// Smooth scrolling is on when `smoothScroll` is present and `smoothScroll.enabled` is not false.
    public var smoothScrollEnabled: Bool {
        get { contains(["smoothScroll"]) && bool(["smoothScroll", "enabled"]) != false }
        set {
            if newValue {
                if !contains(["smoothScroll"]) { set([String: Any](), at: ["smoothScroll"]) }
                set(nil, at: ["smoothScroll", "enabled"])
            } else if contains(["smoothScroll"]) {
                // Keeps the tuning, so turning it back on restores the same feel.
                set(false, at: ["smoothScroll", "enabled"])
            }
        }
    }

    /// Handing the mouse back while the pointer is on another Mac; on unless `universalControl.handOff`
    /// is false. On removes the key, since it is the default.
    public var universalControlHandOff: Bool {
        get { bool(["universalControl", "handOff"]) != false }
        set { set(newValue ? nil : false, at: ["universalControl", "handOff"]) }
    }

    public var dpiPresets: [Int] {
        get { (self[["dpiPresets"]] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [] }
        set { set(newValue.isEmpty ? nil : newValue, at: ["dpiPresets"]) }
    }

    public var feel: Feel {
        Feel.matching(acceleration: double(["smoothScroll", "acceleration"]),
                      smoothingMs: double(["smoothScroll", "smoothingMs"]))
    }

    /// The Feel segment selected: none while the values match no preset.
    public var feelSelection: Feel? { feel == .custom ? nil : feel }

    /// Restore Defaults on Mouse › Buttons: every button, its directions, and the gesture distance
    /// and repeat. App settings stay.
    public mutating func restoreButtonDefaults() {
        set(nil, at: ["buttons"])
        set(nil, at: ["gesture"])
    }

    /// Restore Defaults on Mouse › Scrolling, Advanced… included: smooth scrolling and its tuning,
    /// the main wheel, and the thumb wheel's keys that Scrolling shows. Any other key under
    /// `thumbWheel`, and app settings, stay.
    public mutating func restoreScrollingDefaults() {
        set(nil, at: ["smoothScroll"])
        set(nil, at: ["scrollWheel"])
        for key in ["inverted", "reversed"] + ThumbWheelChoice.keys { set(nil, at: ["thumbWheel", key]) }
    }

    public mutating func apply(_ feel: Feel) {
        guard let values = feel.values else { return }
        if !contains(["smoothScroll"]) { set([String: Any](), at: ["smoothScroll"]) }
        set(values.acceleration, at: ["smoothScroll", "acceleration"])
        set(values.smoothingMs, at: ["smoothScroll", "smoothingMs"])
    }

    /// The key in `buttons` that holds a control's binding. The daemon accepts a name or a hex ID
    /// for the same control ("back", "0x0053", "53"), so a hand-written hex key is read and edited
    /// in place rather than shadowed by a second key. Without one, `button` itself. `scope` is
    /// where `buttons` lives: the top level, an app or a device.
    func buttonKey(_ button: String, in scope: ConfigScope = .global) -> String {
        guard let buttons = self[entryPrefix(for: scope) + ["buttons"]] as? [String: Any], buttons[button] == nil,
              let cid = NamedButton.cid(forKey: button) else { return button }
        return buttons.keys.sorted().first { NamedButton.cid(forKey: $0) == cid } ?? button
    }

    /// The binding `scope` itself sets for a button (`.standard` when it sets none), not what
    /// applies there: for that, `resolved(["buttons", button], in:)`.
    public func binding(_ button: String, in scope: ConfigScope = .global) -> ButtonAction {
        ButtonAction(json: self[entryPrefix(for: scope) + ["buttons", buttonKey(button, in: scope)]])
    }

    public func gestureBinding(_ button: String, _ direction: String, in scope: ConfigScope = .global) -> ButtonAction {
        ButtonAction(json: self[entryPrefix(for: scope) + ["buttons", buttonKey(button, in: scope), direction]])
    }

    /// Binds a button. `.gesture` keeps an existing gesture, or starts one whose click does what
    /// the button did (in a device, what applied there), so a gesture object is never empty (an
    /// empty one is not a gesture). A mouse whose top level already makes the button a gesture
    /// writes nothing: the gesture, click included, applies there already.
    public mutating func bind(_ button: String, to binding: ButtonAction, in scope: ConfigScope = .global) {
        let button = buttonKey(button, in: scope)
        let path = ["buttons", button]
        switch binding {
        case .standard: set(nil, at: path, in: scope)
        case .named(let name): set(name, at: path, in: scope)
        case .keys(let spec): set(["keys": spec], at: path, in: scope)
        case .run(let command): set(["run": command], at: path, in: scope)
        case .haptic(let waveform): set(["haptic": waveform], at: path, in: scope)
        case .gesture:
            if case .gesture = self.binding(button, in: scope) { return }
            var before = self[entryPrefix(for: scope) + path]
            if before == nil, scope.deviceKey != nil {
                let inherited = resolved(path, in: scope)
                if ButtonAction(json: inherited) == .gesture { return }
                before = inherited
            }
            let click: Any = before.flatMap { $0 is String || $0 is [String: Any] ? $0 : nil } ?? "none"
            set(["click": click], at: path, in: scope)
        }
    }

    /// Binds one direction of a gesture button. At the top level a missing direction does nothing,
    /// so "Do Nothing" removes the key, unless it is the last one. In a device (or app) a missing
    /// direction takes the top level's, so "Do Nothing" is written as given, and only `.standard`
    /// removes the key, and the whole binding with its last direction (an empty gesture is not one).
    public mutating func bind(_ button: String, direction: String, to binding: ButtonAction, in scope: ConfigScope = .global) {
        let button = buttonKey(button, in: scope)
        let path = ["buttons", button, direction]
        let own = self[entryPrefix(for: scope) + ["buttons", button]] as? [String: Any]
        switch binding {
        case .standard:
            let others = own?.keys.filter { $0 != direction } ?? []
            if scope == .global {
                set(others.isEmpty ? "none" : nil, at: path, in: scope)
            } else if own != nil {
                set(nil, at: others.isEmpty ? ["buttons", button] : path, in: scope)
            }
        case .named("none") where scope == .global:
            set((own?.keys.filter { $0 != direction } ?? []).isEmpty ? "none" : nil, at: path, in: scope)
        case .named(let name): set(name, at: path, in: scope)
        case .keys(let spec): set(["keys": spec], at: path, in: scope)
        case .run(let command): set(["run": command], at: path, in: scope)
        case .haptic(let waveform): set(["haptic": waveform], at: path, in: scope)
        case .gesture: break
        }
    }
}
