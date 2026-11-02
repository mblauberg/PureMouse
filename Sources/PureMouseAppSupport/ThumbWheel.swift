import Foundation
import PureMouseKit

/// What the thumb wheel's pop-up offers, read from and written to `thumbWheel.action`, `left`,
/// `right` and `step` (docs/configuration.md, "Thumb wheel"); `reversed` has its own row. The same keys under
/// `apps.<id>.thumbWheel` and `devices.<key>.thumbWheel` apply on top of the global ones, so an app
/// or a mouse also has `inherit`.
public enum ThumbWheelChoice: Hashable, Identifiable, Sendable {
    /// Per app or per mouse only: it sets none of `action`, `left` and `right`.
    case inherit
    case scroll
    /// One of Kit's `Config.ThumbWheel.presets` by its config name.
    case preset(String)
    /// `left` or `right` set by hand (or an `action` this app does not know).
    case custom

    public var id: Self { self }

    /// Kit's preset names in the order the pop-up lists them.
    static let presetOrder = ["zoom", "volume", "tabs", "spaces"]

    /// The pop-up's choices after "Same as Everywhere".
    public static let menu: [ThumbWheelChoice] = [.scroll] + presetOrder.map(ThumbWheelChoice.preset) + [.custom]

    public var label: String {
        switch self {
        case .inherit: "Same as Everywhere"
        case .scroll: "Scroll Sideways"
        case .preset("zoom"): "Zoom"
        case .preset("volume"): "Volume"
        case .preset("tabs"): "Switch Tabs"
        case .preset("spaces"): "Switch Spaces"
        case .preset(let name): name
        case .custom: "Custom"
        }
    }

    /// The keys this choice owns; anything else under `thumbWheel` (`inverted`, `reversed`,
    /// unknown keys) stays.
    public static let keys = ["action", "left", "right", "step"]

    /// The choice the keys in `object` make. Outside an app no key means the default, scrolling.
    static func read(_ object: [String: Any]?, inApp: Bool) -> ThumbWheelChoice {
        let object = object ?? [:]
        if object["left"] != nil || object["right"] != nil { return .custom }
        switch object["action"] {
        case nil: return inApp ? .inherit : .scroll
        case "scroll" as String: return .scroll
        case let name as String where Config.ThumbWheel.presets[name] != nil: return .preset(name)
        default: return .custom
        }
    }
}

/// What the thumb wheel does once a set of keys is applied: scroll (no pair) or an action pair,
/// the step and whether the pair is reversed. Mirrors `Config.ThumbWheel.init(_:base:)`, so an app's keys resolve on top of
/// the global state exactly as the daemon resolves them.
public struct ThumbWheelState: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public var left: ButtonAction
        public var right: ButtonAction
    }

    /// nil: the wheel scrolls.
    public var pair: Pair?
    public var step: Int
    /// Swaps which action each direction performs.
    public var reversed = false

    /// No keys at all: scrolling, with Kit's default step.
    public static let initial = ThumbWheelState(pair: nil, step: Config.ThumbWheel.defaultStep)

    public var scrolls: Bool { pair == nil }

    /// The state after the keys in `object`, on top of this one.
    func applying(_ object: [String: Any]?) -> ThumbWheelState {
        guard let object else { return self }
        var state = self
        switch object["action"] {
        case "scroll" as String:
            state.pair = nil
        case let name as String:
            if let preset = Self.preset(name) {
                if state.pair != preset.pair { state.step = preset.step }
                state.pair = preset.pair
            }
        default:
            break
        }
        let left = object["left"].map(ButtonAction.init(json:))
        let right = object["right"].map(ButtonAction.init(json:))
        if left != nil || right != nil {
            let current = state.pair ?? Pair(left: .named("none"), right: .named("none"))
            state.pair = Pair(left: left ?? current.left, right: right ?? current.right)
        }
        if let step = (object["step"] as? NSNumber).flatMap({ JSON.isBool($0) ? nil : $0.intValue }),
           Config.ThumbWheel.stepRange.contains(step) {
            state.step = step
        }
        if let reversed = object["reversed"] as? NSNumber, JSON.isBool(reversed) {
            state.reversed = reversed.boolValue
        }
        return state
    }

    /// A preset's pair, as named actions, and its default step.
    static func preset(_ name: String) -> (pair: Pair, step: Int)? {
        guard let preset = Config.ThumbWheel.presets[name],
              let left = actionName(preset.left), let right = actionName(preset.right) else { return nil }
        return (Pair(left: .named(left), right: .named(right)), preset.step)
    }

    /// The config name of a named action.
    static func actionName(_ action: Action) -> String? {
        Action.named.first { $0.value == action }?.key
    }
}

extension ButtonAction {
    /// The config JSON for this action, as `bind` writes it. Default and Hold and Move have no
    /// form outside a button, so they write "none".
    public var json: Any {
        switch self {
        case .named(let name): name
        case .keys(let spec): ["keys": spec]
        case .run(let command): ["run": command]
        case .haptic(let waveform): ["haptic": waveform]
        case .standard, .gesture: "none"
        }
    }
}

extension ConfigTree {
    /// Whether `path` is an app's or a mouse's, which may leave a key to the top level.
    static func leavesToWiderScope(_ path: [String]) -> Bool { path.first == "apps" || path.first == "devices" }

    /// The thumb wheel state the keys at `path` resolve to, on top of `base`.
    public func thumbWheel(at path: [String], base: ThumbWheelState = .initial) -> ThumbWheelState {
        base.applying(self[path] as? [String: Any])
    }

    /// Whether the thumb wheel scrolls in some app (by its own keys or the global ones), where
    /// `inverted` matters even while it has actions everywhere else.
    public var someAppScrollsThumbWheel: Bool {
        let global = thumbWheel(at: ["thumbWheel"])
        let apps = self[["apps"]] as? [String: Any] ?? [:]
        return apps.keys.contains { thumbWheel(at: ["apps", $0, "thumbWheel"], base: global).scrolls }
    }

    public func thumbWheelChoice(at path: [String]) -> ThumbWheelChoice {
        ThumbWheelChoice.read(self[path] as? [String: Any], inApp: Self.leavesToWiderScope(path))
    }

    /// Writes (or, for nil, removes) one thumb-wheel key at `path + [key]`. In a mouse's entry a
    /// removal keeps the shadow another spelling of its key needs (`removeKeepingShadow`).
    public mutating func setThumbWheelKey(_ value: Any?, _ key: String, at path: [String]) {
        put(value, at: path + [key])
    }

    private mutating func put(_ value: Any?, at path: [String]) {
        if value == nil, path.count > 2, path[0] == "devices" {
            guard contains(path) else { return }
            removeKeepingShadow(at: path, entry: Array(path.prefix(2)))
        } else {
            set(value, at: path)
        }
    }

    /// Writes a choice from the pop-up. A preset sets `action` and drops the step, so it brings
    /// its own; Custom writes the current pair as `left` and `right`, so the wheel does the same
    /// until one is changed, and keeps the step it had.
    public mutating func chooseThumbWheel(_ choice: ThumbWheelChoice, at path: [String], base: ThumbWheelState = .initial) {
        let inApp = Self.leavesToWiderScope(path)
        switch choice {
        case .inherit:
            for key in ThumbWheelChoice.keys { put(nil, at: path + [key]) }
        case .scroll:
            put(inApp ? "scroll" : nil, at: path + ["action"])
            for key in ["left", "right", "step"] { put(nil, at: path + [key]) }
        case .preset(let name):
            put(name, at: path + ["action"])
            for key in ["left", "right", "step"] { put(nil, at: path + [key]) }
        case .custom:
            guard thumbWheelChoice(at: path) != .custom else { return }
            let current = thumbWheel(at: path, base: base)
            let pair = current.pair ?? .init(left: .named("none"), right: .named("none"))
            put(nil, at: path + ["action"])
            put(nil, at: path + ["step"])
            put(pair.left.json, at: path + ["left"])
            put(pair.right.json, at: path + ["right"])
            if thumbWheel(at: path, base: base).step != current.step {
                put(current.step, at: path + ["step"])
            }
        }
    }

    /// The `reversed` key at `path`: nil when absent (an app then follows the global one).
    public func thumbWheelReversed(at path: [String]) -> Bool? {
        bool(path + ["reversed"])
    }

    /// Sets `reversed`. Globally false is the default, so it removes the key; in an app nil
    /// removes it (Same as Everywhere) and false is kept, overriding a reversed global.
    public mutating func setThumbWheelReversed(_ reversed: Bool?, at path: [String]) {
        let inApp = Self.leavesToWiderScope(path)
        put(inApp ? reversed : (reversed == true ? true : nil), at: path + ["reversed"])
    }

    /// The config key that holds what turning the wheel one way ("left" or "right") does.
    public static func thumbWheelKey(turning direction: String, reversed: Bool) -> String {
        reversed ? (direction == "left" ? "right" : "left") : direction
    }

    /// Sets what turning one way does ("left" or "right").
    public mutating func setThumbWheel(_ direction: String, to action: ButtonAction, at path: [String]) {
        put(action.json, at: path + [direction])
    }
}
