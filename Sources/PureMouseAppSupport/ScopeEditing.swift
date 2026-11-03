import Foundation
import PureMouseKit

/// What Mouse › Pointer, Scrolling and Buttons read and write for one scope: All Mice (the top
/// level) or one mouse (`devices.<key>`). Reads go through `resolved` and `isOverridden`; writes
/// through `set(_:at:in:name:)`, so a value lands only in the scope and a removal hands the setting
/// back to All Mice (docs/configuration.md, "Settings and per-mouse values").
extension ConfigTree {
    /// Where `scope`'s own object lives in the tree: the entry the decoder keeps for a mouse, else
    /// where its first write goes.
    public func prefix(of scope: ConfigScope) -> [String] { entryPrefix(for: scope) }

    /// Gives a device entry the edits left in it a `name` (`name` is the mouse's, else its key) and
    /// removes one left holding only its `name`. A write at a raw path under `prefix(of:)` (the
    /// thumb wheel's helpers) creates an entry without one.
    public mutating func settleEntry(for scope: ConfigScope, name: String?) {
        guard let key = scope.deviceKey else { return }
        let entry = entryPrefix(for: scope)
        guard let rest = self[entry] as? [String: Any] else { return }
        if rest.keys.allSatisfy({ $0 == "name" }) {
            pruneIfNameOnly(entry)
        } else if rest["name"] == nil {
            set(name ?? entryName ?? key, at: entry + ["name"])
        }
    }

    // MARK: Values

    /// Whether the config holds a value at `path` in `scope`, which keeps a control shown for a mouse
    /// that lacks it (`ControlAvailability`). A mouse counts only its own value: one All Mice sets
    /// is not a reason to show a control the mouse does not have, nor is one the default set gives.
    public func holds(_ path: [String], in scope: ConfigScope) -> Bool {
        scope.deviceKey == nil ? holdsBeyondDefaults(path) : isOverridden(path, in: scope)
    }

    /// A number at `path` as it applies in `scope`, or `fallback`.
    public func number(_ path: [String], in scope: ConfigScope, default fallback: Double) -> Double {
        resolvedDouble(path, in: scope) ?? fallback
    }

    /// Hands `paths` back to the wider scope: removes the scope's own value. The "Use All Mice
    /// Setting" action. A no-op in All Mice, which has none wider.
    public mutating func removeOverrides(_ paths: [[String]], in scope: ConfigScope) {
        guard scope != .global else { return }
        for path in paths { set(nil, at: path, in: scope) }
    }

    // MARK: Smooth scrolling

    /// Smooth scrolling as it applies in `scope`: on unless the mouse or All Mice says
    /// `enabled: false` (the default set has it on).
    public func smoothScrollEnabled(in scope: ConfigScope) -> Bool {
        guard scope.deviceKey != nil else { return smoothScrollEnabled }
        return resolvedBool(["smoothScroll", "enabled"], in: scope) != false
    }

    /// What the mouse itself says about smooth scrolling: its `enabled`. nil leaves it to All Mice.
    public func smoothScrollOwn(in scope: ConfigScope) -> Bool? {
        guard scope.deviceKey != nil else { return smoothScrollEnabled }
        return isOverridden(["smoothScroll", "enabled"], in: scope) ? resolvedBool(["smoothScroll", "enabled"], in: scope) : nil
    }

    /// Sets smooth scrolling in `scope`; nil (a mouse only) gives it back to All Mice by removing
    /// the mouse's `enabled`, and its `smoothScroll` when that leaves it empty.
    public mutating func setSmoothScroll(_ on: Bool?, in scope: ConfigScope) {
        guard scope.deviceKey != nil else {
            if let on { smoothScrollEnabled = on }
            return
        }
        if let on {
            set(on, at: ["smoothScroll", "enabled"], in: scope)
        } else {
            set(nil, at: ["smoothScroll", "enabled"], in: scope)
            // What is left empty says nothing next to the top level's own `smoothScroll`.
            if (self[entryPrefix(for: scope) + ["smoothScroll"]] as? [String: Any])?.isEmpty == true {
                set(nil, at: ["smoothScroll"], in: scope)
            }
        }
    }

    // MARK: Feel

    /// The Feel preset the values in effect in `scope` match: none for values no preset matches.
    public func feelSelection(in scope: ConfigScope) -> Feel? {
        let feel = Feel.matching(acceleration: resolvedDouble(["smoothScroll", "acceleration"], in: scope),
                                 smoothingMs: resolvedDouble(["smoothScroll", "smoothingMs"], in: scope))
        return feel == .custom ? nil : feel
    }

    /// The Feel a mouse sets itself (`.custom` for values no preset matches), nil when it sets
    /// neither value and follows All Mice. nil for All Mice.
    public func ownFeel(in scope: ConfigScope) -> Feel? {
        guard scope.deviceKey != nil,
              isOverridden(["smoothScroll", "acceleration"], in: scope) || isOverridden(["smoothScroll", "smoothingMs"], in: scope)
        else { return nil }
        return feelSelection(in: scope) ?? .custom
    }

    /// The Feel All Mice has (`.custom` for values no preset matches).
    public var globalFeel: Feel { feelSelection(in: .global) ?? .custom }

    public mutating func apply(_ feel: Feel, in scope: ConfigScope) {
        guard scope.deviceKey != nil else { return apply(feel) }
        guard let values = feel.values else { return }
        set(values.acceleration, at: ["smoothScroll", "acceleration"], in: scope)
        set(values.smoothingMs, at: ["smoothScroll", "smoothingMs"], in: scope)
    }

    // MARK: DPI

    /// The preset list in effect in `scope`: a mouse's own list replaces All Mice's.
    public func dpiPresets(in scope: ConfigScope) -> [Int] {
        (resolved(["dpiPresets"], in: scope) as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
    }

    /// Saves the list. A mouse keeps an empty one (no presets for it); All Mice drops the key.
    public mutating func setDPIPresets(_ presets: [Int], in scope: ConfigScope) {
        set(presets.isEmpty && scope.deviceKey == nil ? nil : presets, at: ["dpiPresets"], in: scope)
    }

    // MARK: Restore Defaults

    /// Restore Defaults on Pointer: `dpi` and `dpiPresets` in `scope`, which the default set leaves
    /// unset. A mouse's keep its `name`.
    public mutating func restorePointerDefaults(in scope: ConfigScope = .global) {
        for key in ["dpi", "dpiPresets"] { set(nil, at: [key], in: scope) }
    }

    /// Restore Defaults on Buttons in `scope`: every button, its directions, and the gesture
    /// distance and repeat. App settings stay.
    public mutating func restoreButtonDefaults(in scope: ConfigScope) {
        for key in ["buttons", "gesture"] { set(nil, at: [key], in: scope) }
    }

    /// Restore Defaults on Scrolling in `scope`, Advanced… included (`restoreScrollingDefaults()`).
    public mutating func restoreScrollingDefaults(in scope: ConfigScope) {
        for key in ["smoothScroll", "scrollWheel"] { set(nil, at: [key], in: scope) }
        for key in ["inverted", "reversed"] + ThumbWheelChoice.keys { set(nil, at: ["thumbWheel", key], in: scope) }
    }

    // MARK: Buttons

    /// The binding that applies to a button in `scope`.
    public func resolvedBinding(_ button: String, in scope: ConfigScope) -> ButtonAction {
        scope.deviceKey == nil ? binding(button, in: scope) : ButtonAction(json: resolved(["buttons", button], in: scope))
    }
}
