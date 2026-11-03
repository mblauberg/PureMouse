import Foundation
import PureMouseKit

/// Editing a button's triggers (ADR 24, #158): its click, Double-click and Hold rows, and Hold and
/// Move's directions. Each trigger inherits on its own, All Mice then the mouse then the app; a bare
/// action replaces the whole binding, so it is written only when no other trigger applies there.
extension ConfigTree {
    /// The binding `scope` itself writes for a button, as the file holds it.
    func ownBinding(_ button: String, in scope: ConfigScope) -> Any? {
        let value = self[entryPrefix(for: scope) + ["buttons", buttonKey(button, in: scope)]]
        return value is NSNull ? nil : value
    }

    /// The binding that applies where `scope` leaves the button alone: nil at the top level. A
    /// mouse's is the top level's; an app's is what the first of the `inheriting` mice resolve.
    func widerBinding(_ button: String, for scope: ConfigScope, inheriting: [ConfigScope]) -> Any? {
        guard scope != .global else { return nil }
        let global = self[["buttons", buttonKey(button)]]
        guard scope.deviceKey == nil, let wider = inheriting.first, wider.deviceKey != nil else {
            return Self.isNative(global) ? nil : global
        }
        return resolved(["buttons", button], in: wider)
    }

    static func table(_ value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any], Gesture.isTable(object) else { return nil }
        return object
    }

    private static func isNative(_ value: Any?) -> Bool { (value as? String) == Config.Binding.nativeValue }

    /// A trigger's value does something: present, not `null`, not `"none"`.
    static func isSet(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        return (value as? String) != "none"
    }

    /// The table that applies at a scope with `own` over `wider`: nil when the binding is no table
    /// (a bare action of the scope's own replaces a wider table).
    static func applyingTable(own: Any?, wider: Any?) -> [String: Any]? {
        guard let own else { return table(wider) }
        guard let mine = table(own) else { return nil }
        return table(wider).map { Gesture.merge(mine, over: $0) } ?? mine
    }

    /// Some trigger other than the click does something.
    static func othersApply(_ table: [String: Any]?) -> Bool {
        guard let table else { return false }
        return table.contains { $0.key != "click" && isSet($0.value) }
    }

    /// The table a scope starts from to add a trigger: its own, or one whose click keeps what the
    /// button did there (a table over a wider bare action starts empty, so that click is copied;
    /// over a wider table it inherits). Mouse Default and no binding give a click that does nothing:
    /// a table's click is PureMouse's, never the mouse's own.
    private func startingTable(_ button: String, in scope: ConfigScope, inheriting: [ConfigScope]) -> [String: Any] {
        let own = ownBinding(button, in: scope)
        if let mine = Self.table(own) { return mine }
        if let own { return ["click": Self.isNative(own) ? "none" : own] }
        let wider = widerBinding(button, for: scope, inheriting: inheriting)
        if Self.table(wider) != nil { return [:] }
        return ["click": wider ?? "none"]
    }

    /// Sets what a click does (the row's pop-up). The other triggers stay: with any applying, the
    /// click goes into the scope's table; with none, the bare action is written. `.standard`
    /// ("Same as …") gives the click back to the wider table, or the whole binding where there is
    /// none; Mouse Default replaces the whole binding (its picker entry is offered only while no
    /// other trigger applies). `.gesture` is Hold and Move (`bindHoldAndMove`).
    public mutating func bindClick(_ button: String, to action: ButtonAction, in scope: ConfigScope = .global,
                                   inheriting: [ConfigScope] = [.global]) {
        if action == .gesture { return bindHoldAndMove(button, in: scope, inheriting: inheriting) }
        let own = ownBinding(button, in: scope)
        let wider = widerBinding(button, for: scope, inheriting: inheriting)
        if action == .standard, var mine = Self.table(own), Self.table(wider) != nil {
            mine["click"] = nil
            return settle(button, mine, in: scope, inheriting: inheriting)
        }
        guard action != .standard, action != .mouseDefault,
              Self.othersApply(Self.applyingTable(own: own, wider: wider)) else {
            return bind(button, to: action, in: scope)
        }
        var table = Self.table(own) ?? [:]
        table["click"] = action.json
        settle(button, table, in: scope, inheriting: inheriting)
    }

    /// Sets a trigger other than the click: `doubleClick`, `hold`, or one of Hold and Move's
    /// directions. A hold form replaces the other. `.standard` ("Same as …") removes the scope's
    /// own (both hold forms, on the Hold row). "No Action" (`"none"`) removes it at the top level,
    /// and on a mouse or in an app writes `"none"` where the wider table sets it, so it is off there.
    public mutating func bindTrigger(_ button: String, _ trigger: String, to action: ButtonAction,
                                     in scope: ConfigScope = .global, inheriting: [ConfigScope] = [.global]) {
        if trigger == "hold", action == .gesture { return bindHoldAndMove(button, in: scope, inheriting: inheriting) }
        let wider = Self.table(widerBinding(button, for: scope, inheriting: inheriting))
        var table = startingTable(button, in: scope, inheriting: inheriting)
        let keys = trigger == "hold" ? ["hold"] + Gesture.directions : [trigger]
        switch action {
        case .standard:
            for key in keys { table[key] = nil }
        case .named("none"):
            for key in keys { table[key] = nil }
            let widerSets = scope != .global && keys.contains { Self.isSet(wider?[$0]) }
            if widerSets {
                table[trigger] = "none"
                if Gesture.directions.contains(trigger) { table["hold"] = nil }
            }
        default:
            let value = action.json
            if trigger == "hold" { for key in Gesture.directions { table[key] = nil } }
            if Gesture.directions.contains(trigger) { table["hold"] = nil }
            table[trigger] = value
        }
        settle(button, table, in: scope, inheriting: inheriting)
    }

    /// Hold and Move as the button's hold form, with the standard directions (up Mission Control,
    /// down App Exposé, left and right Spaces). Nothing changes where it applies already. Over a
    /// mouse or app set to Mouse Default it gives the wider Hold and Move back whole.
    public mutating func bindHoldAndMove(_ button: String, in scope: ConfigScope = .global,
                                         inheriting: [ConfigScope] = [.global]) {
        let own = ownBinding(button, in: scope)
        let wider = widerBinding(button, for: scope, inheriting: inheriting)
        let moves = { (table: [String: Any]?) in Gesture.directions.contains { Self.isSet(table?[$0]) } }
        if moves(Self.applyingTable(own: own, wider: wider)) { return }
        if scope != .global, Self.isNative(own), moves(Self.table(wider)) {
            return bind(button, to: .standard, in: scope)
        }
        var table = startingTable(button, in: scope, inheriting: inheriting)
        table["hold"] = nil
        table.merge(Gesture.standardDirections) { _, standard in standard }
        settle(button, table, in: scope, inheriting: inheriting)
    }

    /// Writes a button's table at `scope`. Where only the click is left doing anything, the bare
    /// click (which replaces the whole binding, so is equivalent); an empty table on a mouse or in
    /// an app gives the button back to the wider scope. At the top level, a trigger the default
    /// set's table gives that `table` leaves out is written as `"none"`, since the default set
    /// would otherwise fill it in.
    private mutating func settle(_ button: String, _ table: [String: Any], in scope: ConfigScope,
                                 inheriting: [ConfigScope]) {
        let path = ["buttons", buttonKey(button, in: scope)]
        let wider = widerBinding(button, for: scope, inheriting: inheriting)
        let applying = Self.table(wider).map { Gesture.merge(table, over: $0) } ?? table
        if let click = table["click"], !Self.othersApply(applying) {
            set(click, at: path, in: scope)
            return
        }
        if table.isEmpty {
            for key in buttonAliases(button, in: scope) { set(nil, at: ["buttons", key], in: scope) }
            return
        }
        var table = table
        if scope == .global, let defaults = Self.table(Self.defaultBinding(for: button)) {
            let ownsHold = table["hold"] != nil, moves = Gesture.directions.contains { table[$0] != nil }
            for key in defaults.keys where table[key] == nil {
                let otherForm = Gesture.directions.contains(key) ? ownsHold : key == "hold" && moves
                if !otherForm { table[key] = "none" }
            }
        }
        set(table, at: path, in: scope)
    }
}

extension ButtonAction {
    /// The label on a trigger row other than the click: an unset one reads No Action.
    public var triggerLabel: String {
        self == .standard || self == .named("none") ? Triggers.noAction : label
    }
}

/// The words for a button's triggers (docs/ui-language.md).
public enum Triggers {
    public static let noAction = "No Action"
    /// The picker section that adds a trigger.
    public static let moreWaysToPress = "More Ways to Press"
    /// Why Double-Click and Hold are off while the click is Precise Pointer, which owns the button.
    public static let removeHoldFirst = "Remove Hold first."

    /// The caption under a Double-click row: what it costs, with the live interval.
    public static func doubleClickCaption(milliseconds: Int) -> String {
        "Single clicks wait \(seconds(milliseconds)) s for a second click."
    }

    /// Milliseconds as seconds, as few decimals as it takes: 500 is "0.5", 1000 is "1".
    static func seconds(_ milliseconds: Int) -> String {
        var text = String(format: "%.2f", Double(milliseconds) / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Hold and Move's directions in words, as the collapsed row says them: each action once, in
    /// the directions' order, and both Spaces as one ("Mission Control, App Exposé, Spaces").
    public static func directionsSummary(_ actions: [ButtonAction]) -> String {
        let set = actions.filter { $0 != .standard && $0 != .named("none") }
        guard !set.isEmpty else { return noAction }
        let spaces = set.contains(.named("spaceLeft")) && set.contains(.named("spaceRight"))
        var words: [String] = []
        for action in set {
            let word = spaces && [.named("spaceLeft"), .named("spaceRight")].contains(action) ? "Spaces" : action.label
            if !words.contains(word) { words.append(word) }
        }
        return words.joined(separator: ", ")
    }
}

extension ConfigTree {
    /// The double-click interval in milliseconds, as the daemon reads it: `doubleClickMs`, else the
    /// system's, `systemSeconds` (`Config.systemDoubleClickKey`).
    public func doubleClickMilliseconds(systemSeconds: Double?) -> Int {
        Config.doubleClickInterval(configured: (self[["doubleClickMs"]] as? NSNumber)?.intValue, systemSeconds: systemSeconds)
    }

    /// The system's double-click interval in seconds, nil when unset.
    public static var systemDoubleClickSeconds: Double? {
        UserDefaults.standard.object(forKey: Config.systemDoubleClickKey) as? Double
    }
}
