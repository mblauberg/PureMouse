import Foundation
import PureMouseKit

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

    /// The keys in `buttons` that spell a control: the daemon accepts a name or a hex ID for the same
    /// control ("back", "0x0053", "53"), so a hand-written file may hold several. In sorted order,
    /// as the decoder reads them. Just `button` for a name that is no control (the decoder skips it).
    /// `scope` is where `buttons` lives: the top level, an app or a device.
    func buttonAliases(_ button: String, in scope: ConfigScope = .global) -> [String] {
        guard let cid = NamedButton.cid(forKey: button),
              let buttons = self[entryPrefix(for: scope) + ["buttons"]] as? [String: Any] else { return [button] }
        let aliases = buttons.keys.sorted().filter { NamedButton.cid(forKey: $0) == cid }
        return aliases.isEmpty ? [button] : aliases
    }

    /// The key in `buttons` that holds a control's binding. When several spell the control, the one
    /// the decoder keeps: the last in sorted order whose value is not null (`Config.decodeButtons`),
    /// so a hand-written hex key is read and edited in place rather than shadowed by a second key.
    /// Without one, `button` itself.
    func buttonKey(_ button: String, in scope: ConfigScope = .global) -> String {
        let buttons = self[entryPrefix(for: scope) + ["buttons"]] as? [String: Any]
        let aliases = buttonAliases(button, in: scope)
        return aliases.last { !(buttons?[$0] is NSNull) } ?? aliases.last ?? button
    }

    /// Gives a control back to the wider scope, or to the mouse at the top level: removes every key
    /// that spells it, since one left behind would apply in its place.
    private mutating func removeButton(_ button: String, in scope: ConfigScope) {
        for key in buttonAliases(button, in: scope) { set(nil, at: ["buttons", key], in: scope) }
    }

    /// The binding `scope` itself sets for a button (`.standard` when it sets none), not what
    /// applies there: for that, `resolved(["buttons", button], in:)`.
    /// `"default"` at the top level is the same as no key, so it reads as `.standard` there.
    public func binding(_ button: String, in scope: ConfigScope = .global) -> ButtonAction {
        let action = ButtonAction(json: self[entryPrefix(for: scope) + ["buttons", buttonKey(button, in: scope)]])
        return action == .mouseDefault && scope == .global ? .standard : action
    }

    public func gestureBinding(_ button: String, _ direction: String, in scope: ConfigScope = .global) -> ButtonAction {
        ButtonAction(json: self[entryPrefix(for: scope) + ["buttons", buttonKey(button, in: scope), direction]])
    }

    /// Binds a button. `.gesture` keeps an existing gesture, or starts one whose click does what
    /// the button did (in a device, what applied there), so a gesture object is never empty (an
    /// empty one is not a gesture). A mouse whose top level already makes the button a gesture
    /// writes nothing: the gesture, click included, applies there already.
    public mutating func bind(_ button: String, to binding: ButtonAction, in scope: ConfigScope = .global) {
        if binding == .standard || (binding == .mouseDefault && scope == .global) {
            removeButton(button, in: scope)
            return
        }
        let button = buttonKey(button, in: scope)
        let path = ["buttons", button]
        switch binding {
        case .standard: break
        // Native on a mouse or in an app while a wider scope binds the button; the top level has
        // no wider scope, so there the key is just removed (above).
        case .mouseDefault: set(Config.Binding.nativeValue, at: path, in: scope)
        case .named(let name): set(name, at: path, in: scope)
        case .keys(let spec): set(["keys": spec], at: path, in: scope)
        case .run(let command): set(["run": command], at: path, in: scope)
        case .haptic(let waveform): set(["haptic": waveform], at: path, in: scope)
        case .gesture:
            if case .gesture = self.binding(button, in: scope) { return }
            // Mouse Default hides the wider gesture. Choosing Hold and Move over it gives the gesture
            // back whole (its directions included), as "Same as …" does.
            if scope != .global, self.binding(button, in: scope) == .mouseDefault, self.binding(button) == .gesture {
                removeButton(button, in: scope)
                return
            }
            var before = self[entryPrefix(for: scope) + path]
            if before == nil, scope.deviceKey != nil {
                let inherited = resolved(path, in: scope)
                if ButtonAction(json: inherited) == .gesture { return }
                before = inherited
            }
            // A mouse set to Mouse Default clicks natively; the gesture's click then does nothing.
            let click: Any = before.flatMap { ButtonAction(json: $0) == .mouseDefault ? nil : $0 }
                .flatMap { $0 is String || $0 is [String: Any] ? $0 : nil } ?? "none"
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
                if others.isEmpty { removeButton(button, in: scope) } else { set(nil, at: path, in: scope) }
            }
        case .named("none") where scope == .global:
            set((own?.keys.filter { $0 != direction } ?? []).isEmpty ? "none" : nil, at: path, in: scope)
        case .named(let name): set(name, at: path, in: scope)
        case .keys(let spec): set(["keys": spec], at: path, in: scope)
        case .run(let command): set(["run": command], at: path, in: scope)
        case .haptic(let waveform): set(["haptic": waveform], at: path, in: scope)
        case .gesture, .mouseDefault: break
        }
    }
}
