import Foundation
import PureMouseKit

/// What a setting resolves to across the mice an app may run with: one value when they agree, else
/// every distinct value in the mice's order. An app page shows the value that applies for the
/// mouse's own settings, not the top level's, and "Varies by Mouse" when the mice differ (#137).
public struct Applied<Value: Equatable & Sendable>: Sendable {
    /// What the row says while the mice resolve the setting differently.
    public static var variesLabel: String { "Varies by Mouse" }
    /// The short form for a readout beside a slider or stepper, which has no room for the whole
    /// phrase without moving the track; VoiceOver and the tooltip still say `variesLabel`.
    public static var variesReadout: String { "Varies" }

    /// The distinct values, in the mice's order. Never empty.
    public let values: [Value]

    public init(_ resolved: [Value]) {
        precondition(!resolved.isEmpty, "Applied needs at least one value")
        var distinct: [Value] = []
        for value in resolved where !distinct.contains(value) { distinct.append(value) }
        values = distinct
    }

    /// The first mouse's value, which the row shows when the mice agree and an edit seeds from.
    public var first: Value { values[0] }

    /// The mice resolve it differently.
    public var varies: Bool { values.count > 1 }
}

extension ConfigTree {
    /// The binding of one gesture direction as `scope` resolves it (a mouse's own, else the top
    /// level's): `.standard` when neither sets it.
    func resolvedGestureBinding(_ button: String, _ direction: String, in scope: ConfigScope) -> ButtonAction {
        guard scope.deviceKey != nil else { return gestureBinding(button, direction, in: scope) }
        return ButtonAction(json: resolved(["buttons", button, direction], in: scope))
    }

    /// The thumb wheel's choice as `scope` resolves it. A mouse's `action`, `left` or `right`
    /// replaces the top level's whole choice, so the choice comes from the mouse's keys when it has
    /// any, else the top level's.
    public func thumbWheelChoice(in scope: ConfigScope) -> ThumbWheelChoice {
        let global = self[["thumbWheel"]] as? [String: Any]
        guard scope.deviceKey != nil,
              let own = self[entryPrefix(for: scope) + ["thumbWheel"]] as? [String: Any],
              ThumbWheelChoice.keys.contains(where: { own[$0] != nil && !($0 == "step") && !(own[$0] is NSNull) })
        else { return ThumbWheelChoice.read(global, inApp: false) }
        return ThumbWheelChoice.read(own, inApp: false)
    }

    /// The thumb wheel's choice for each of the mice (`inheriting`), as one value or several.
    public func thumbWheelChoice(inheriting scopes: [ConfigScope]) -> Applied<ThumbWheelChoice> {
        Applied((scopes.isEmpty ? [.global] : scopes).map { thumbWheelChoice(in: $0) })
    }

    /// The thumb wheel differs between the mice: they choose differently, or the same kind of
    /// choice (Custom) does different things. Reading two mice's `custom` as one choice would show
    /// the first mouse's actions as shared. What each way of turning does counts as the wheel
    /// turns, so one mouse's swapped directions differ from another's that are not.
    public func thumbWheelVaries(inheriting scopes: [ConfigScope]) -> Bool {
        thumbWheelChoice(inheriting: scopes).varies
            || Applied(thumbWheelState(inheriting: scopes).values.map { state in
                state.pair.map { state.reversed ? [$0.right, $0.left] : [$0.left, $0.right] }
            }).varies
    }

    /// What one way of turning the thumb wheel does on each of the mice (`key` is `left` or
    /// `right`, as the keys are written), as one action or several. No pair is no action.
    public func thumbWheelAction(_ key: String, inheriting scopes: [ConfigScope]) -> Applied<ButtonAction> {
        Applied((scopes.isEmpty ? [.global] : scopes).map { scope in
            thumbWheel(in: scope).pair.map { key == "left" ? $0.left : $0.right } ?? .named("none")
        })
    }

    /// The thumb wheel's keys (`left`, `right`, `step`, `reversed`) that come out different on the
    /// mice, which an app that leaves them alone says "Varies by Mouse" for. With `ownPath` (the
    /// app's `thumbWheel`), its own keys are applied on each mouse's state first, as the daemon
    /// layers them: a value the app sets agrees everywhere, and an action it picks brings its own
    /// step. `left` and `right` are the keys as written, so they also vary when only the swap differs.
    public func thumbWheelKeysVarying(inheriting scopes: [ConfigScope], ownPath: [String]? = nil) -> Set<String> {
        let states = (scopes.isEmpty ? [.global] : scopes).map { scope in
            let mouse = thumbWheel(in: scope)
            return ownPath.map { thumbWheel(at: $0, base: mouse) } ?? mouse
        }
        func pick(_ key: String, _ pair: ThumbWheelState.Pair?) -> ButtonAction {
            pair.map { key == "left" ? $0.left : $0.right } ?? .named("none")
        }
        var keys: Set<String> = []
        for key in ["left", "right"] where Applied(states.map { pick(key, $0.pair) }).varies { keys.insert(key) }
        if Applied(states.map(\.step)).varies { keys.insert("step") }
        if Applied(states.map(\.reversed)).varies {
            keys.insert("reversed")
            // Swapped on one mouse and not on another, a way of turning does one thing on one and the
            // other thing on the other, unless both ways do the same.
            if states.contains(where: { $0.pair.map { $0.left != $0.right } ?? false }) { keys.formUnion(["left", "right"]) }
        }
        return keys
    }

    /// A number as it applies on each of the mice, as one value or several.
    public func appliedNumber(_ path: [String], inheriting scopes: [ConfigScope], default fallback: Double) -> Applied<Double> {
        Applied((scopes.isEmpty ? [.global] : scopes).map { number(path, in: $0, default: fallback) })
    }

    /// What the thumb wheel does on each of the mice, as one state or several.
    public func thumbWheelState(inheriting scopes: [ConfigScope]) -> Applied<ThumbWheelState> {
        Applied((scopes.isEmpty ? [.global] : scopes).map { thumbWheel(in: $0) })
    }
}

extension AppModel {
    /// The scopes an app's unset settings fall back to: one per known mouse, since the daemon layers
    /// an app over the mouse that is in use (`Config.forDevice(_:)`); the top level when no mouse is
    /// known.
    public var appInheritedScopes: [ConfigScope] {
        let scopes = knownMice.compactMap { ConfigScope.device($0.key) }
        return scopes.isEmpty ? [.global] : scopes
    }
}
