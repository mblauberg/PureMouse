import Foundation

/// Config settings with meaning beyond one key.
extension ConfigTree {
    /// Smooth scrolling is on when `smoothScroll` is present and `smoothScroll.enabled` is not false.
    var smoothScrollEnabled: Bool {
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

    var dpiPresets: [Int] {
        get { (self[["dpiPresets"]] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [] }
        set { set(newValue.isEmpty ? nil : newValue, at: ["dpiPresets"]) }
    }

    var feel: Feel {
        Feel.matching(acceleration: double(["smoothScroll", "acceleration"]),
                      smoothingMs: double(["smoothScroll", "smoothingMs"]))
    }

    mutating func apply(_ feel: Feel) {
        guard let values = feel.values else { return }
        if !contains(["smoothScroll"]) { set([String: Any](), at: ["smoothScroll"]) }
        set(values.acceleration, at: ["smoothScroll", "acceleration"])
        set(values.smoothingMs, at: ["smoothScroll", "smoothingMs"])
    }

    func binding(_ button: String) -> ButtonAction { ButtonAction(json: self[["buttons", button]]) }

    func gestureBinding(_ button: String, _ direction: String) -> ButtonAction {
        ButtonAction(json: self[["buttons", button, direction]])
    }

    /// Binds a button. `.gesture` keeps an existing gesture, or starts one whose click does what
    /// the button did, so a gesture object is never empty (an empty one is not a gesture).
    mutating func bind(_ button: String, to binding: ButtonAction) {
        let path = ["buttons", button]
        switch binding {
        case .standard: set(nil, at: path)
        case .named(let name): set(name, at: path)
        case .keys(let spec): set(["keys": spec], at: path)
        case .run(let command): set(["run": command], at: path)
        case .gesture:
            if case .gesture = self.binding(button) { return }
            let click: Any = self[path].flatMap { $0 is String || $0 is [String: Any] ? $0 : nil } ?? "none"
            set(["click": click], at: path)
        }
    }

    /// Binds one direction of a gesture button. A missing direction does nothing, so "Do Nothing"
    /// removes the key, unless it is the last one.
    mutating func bind(_ button: String, direction: String, to binding: ButtonAction) {
        let path = ["buttons", button, direction]
        switch binding {
        case .standard, .named("none"):
            let others = (self[["buttons", button]] as? [String: Any])?.keys.filter { $0 != direction } ?? []
            set(others.isEmpty ? "none" : nil, at: path)
        case .named(let name): set(name, at: path)
        case .keys(let spec): set(["keys": spec], at: path)
        case .run(let command): set(["run": command], at: path)
        case .gesture: break
        }
    }
}
