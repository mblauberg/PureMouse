import Foundation
import PureMouseKit

/// Where a setting lives in the config: a path prefix. `.global` is the top level (every mouse),
/// `.device(key)` is `devices.<key>`, `.app(id)` is `apps.<id>` (docs/adr/0012-multi-device-settings-scopes.md).
/// A device scope exists only for a key Kit accepts (`Config.isDeviceKey`), so no write can build an
/// entry the decoder would skip.
public struct ConfigScope: Hashable, Sendable {
    public let prefix: [String]

    private init(prefix: [String]) { self.prefix = prefix }

    public static let global = ConfigScope(prefix: [])

    /// The scope of one mouse, or nil for a key Kit rejects: `m` plus 12 lowercase hex digits that
    /// are not a placeholder, or `p` plus 4.
    public static func device(_ key: String) -> ConfigScope? {
        Config.isDeviceKey(key) ? ConfigScope(prefix: ["devices", key]) : nil
    }

    /// The scope of one app, by its key under `apps` (`ConfigTree.appKey`).
    public static func app(_ key: String) -> ConfigScope { ConfigScope(prefix: ["apps", key]) }

    /// The device key, for a device scope.
    public var deviceKey: String? { prefix.count == 2 && prefix[0] == "devices" ? prefix[1] : nil }
}

/// Reading and writing settings in a scope. A device entry is decoded on top of the top level by
/// Kit's decoder (`Config.decodeSections`); `resolved` mirrors that merge, and a parity test checks
/// it against `Config.forDevice` on generated trees.
extension ConfigTree {
    // MARK: Entries

    /// The mice `devices` names: device key (lowercase, as the decoder matches it) to the entry's
    /// `name`, or the key when it has none. Entries whose key Kit rejects are skipped, as the
    /// decoder does.
    public var deviceEntries: [String: String] {
        guard let devices = self[["devices"]] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for raw in devices.keys.sorted() {
            let key = raw.lowercased()
            guard Config.isDeviceKey(key), let entry = devices[raw] as? [String: Any] else { continue }
            out[key] = entry["name"] as? String ?? key
        }
        return out
    }

    // MARK: Reading

    /// The value at `path` (from the config root, as `self[path]`) that applies in `scope`.
    /// - A device scope falls back per leaf to the top level, as the daemon merges them: `dpi` and
    ///   a `dpiPresets` list replace; `scrollWheel`, `thumbWheel`, `smoothScroll` and `gesture`
    ///   merge per key (an object path returns the merged object); `buttons` merge per control,
    ///   whatever name or hex ID spells it, and a gesture per direction. `buttons`, then a name,
    ///   then a direction narrows the answer. Anything else is the top level's, since a device
    ///   entry cannot set it.
    /// - `thumbWheel` is per key here, but its `action` also resets `step` and replaces `left` and
    ///   `right`, which only layering gets right: read the wheel with `thumbWheel(in:)`.
    /// - Any other scope has no wider one to fall back to: its own value, as `self[prefix + path]`.
    public func resolved(_ path: [String], in scope: ConfigScope) -> Any? {
        guard let key = scope.deviceKey else { return value(scope.prefix + path) }
        guard let section = path.first, Config.deviceSections.contains(section) else { return value(path) }
        let entry = (self[["devices", key]] as? [String: Any]) ?? [:]
        if section == "buttons" { return resolvedButtons(Array(path.dropFirst()), device: entry) }
        let global = Self.lookup(root, path)
        guard let own = Self.lookup(entry, path) else { return global }
        if path.count == 1, let own = own as? [String: Any], let global = global as? [String: Any] {
            return global.merging(own) { _, own in own }
        }
        return own
    }

    /// Whether `scope` itself sets the value at `path` (relative to the root, as `resolved`),
    /// rather than leaving it to the top level. Always false for the top level, and for a section a
    /// device entry cannot set. A button counts under whichever name or hex ID spells it.
    public func isOverridden(_ path: [String], in scope: ConfigScope) -> Bool {
        guard scope != .global else { return false }
        if scope.deviceKey != nil, !path.isEmpty, !Config.deviceSections.contains(path[0]) { return false }
        var path = path
        if path.count >= 2, path[0] == "buttons" { path[1] = buttonKey(path[1], in: scope) }
        return value(scope.prefix + path) != nil
    }

    /// The thumb wheel in `scope` as the daemon resolves it: the top level's keys, then the
    /// scope's on top (`Config.ThumbWheel.init(_:base:)`, where `action` resets the step and `left`
    /// and `right` replace one direction each).
    public func thumbWheel(in scope: ConfigScope) -> ThumbWheelState {
        let global = thumbWheel(at: ["thumbWheel"])
        guard scope != .global else { return global }
        return global.applying(self[scope.prefix + ["thumbWheel"]] as? [String: Any])
    }

    // MARK: Writing

    /// Sets the value at `path` in `scope`, or removes it when `value` is nil. Returns false, and
    /// changes nothing, when a device scope is asked for a key that is not one of Kit's device
    /// sections (`Config.deviceSections`): `apps`, `universalControl`, `notifications` and `name`
    /// are not written under a device.
    ///
    /// The first value written under a device creates its entry, with `name` (the mouse's name,
    /// else its key) written once; an entry that already exists keeps its own. Removing the last
    /// override removes the entry, as a name-only entry says nothing, but an entry that holds any
    /// other key (one this app does not know) stays. Removing what is not there changes nothing.
    @discardableResult
    public mutating func set(_ value: Any?, at path: [String], in scope: ConfigScope, name: String? = nil) -> Bool {
        guard let key = scope.deviceKey else {
            set(value, at: scope.prefix + path)
            return true
        }
        guard let section = path.first, Config.deviceSections.contains(section) else { return false }
        let entry = scope.prefix
        let target = entry + path
        if value == nil {
            guard contains(target) else { return true }
            set(nil, at: target)
            if let rest = self[entry] as? [String: Any], rest.keys.allSatisfy({ $0 == "name" }) {
                set(nil, at: entry)
            }
        } else {
            if !(self[entry] is [String: Any]) { set(name ?? key, at: entry + ["name"]) }
            set(value, at: target)
        }
        return true
    }

    // MARK: Helpers

    /// The value at `path`, with JSON null read as absent, as the decoder reads it.
    private func value(_ path: [String]) -> Any? { Self.lookup(root, path) }

    private static func lookup(_ dict: [String: Any], _ path: [String]) -> Any? {
        var node: Any = dict
        for key in path {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        return node is NSNull ? nil : node
    }

    /// What a gesture object looks like to the decoder: some keys, all of them directions.
    private static func isGestureShape(_ value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any], !object.isEmpty,
              object.keys.allSatisfy(Gesture.directions.contains) else { return nil }
        return object
    }

    /// The binding for a control among the names `buttons` gives it: when several spell the same
    /// control, the decoder keeps the last in sorted order.
    private static func binding(for cid: UInt16, in buttons: [String: Any]) -> (name: String, value: Any)? {
        buttons.keys.sorted().last { NamedButton.cid(forKey: $0) == cid }.flatMap { name in
            buttons[name].map { (name, $0) }
        }
    }

    /// `buttons` in a device: per control, the device's binding over the top level's, a gesture
    /// per direction when both are gestures (`Config.Binding.decode`). Reserved controls (the
    /// primary clicks) are never bound. `rest` is what follows `buttons`: nothing (all of them), a
    /// button name, then keys inside its binding.
    private func resolvedButtons(_ rest: [String], device: [String: Any]) -> Any? {
        let global = self[["buttons"]] as? [String: Any]
        let own = device["buttons"] as? [String: Any]
        guard let name = rest.first else {
            guard global != nil || own != nil else { return nil }
            var names: [String: String] = [:]  // a control, or an unknown name, to the name that spells it
            for buttons in [global ?? [:], own ?? [:]] {
                for key in buttons.keys.sorted() {
                    if let cid = NamedButton.cid(forKey: key) {
                        if !Config.reservedControls.contains(cid) { names["cid:\(cid)"] = key }
                    } else {
                        names[key] = key
                    }
                }
            }
            var out: [String: Any] = [:]
            for key in names.values.sorted() {
                if let binding = resolvedButtons([key], device: device) { out[key] = binding }
            }
            return out
        }
        var binding: Any?
        if let cid = NamedButton.cid(forKey: name) {
            guard !Config.reservedControls.contains(cid) else { return nil }
            let base = global.flatMap { Self.binding(for: cid, in: $0) }?.value
            if let top = own.flatMap({ Self.binding(for: cid, in: $0) })?.value {
                if let top = Self.isGestureShape(top), let base = Self.isGestureShape(base) {
                    binding = base.merging(top) { _, top in top }
                } else {
                    binding = top
                }
            } else {
                binding = base
            }
        } else {
            binding = own?[name] ?? global?[name]
        }
        guard let binding, rest.count > 1 else { return binding }
        return Self.lookup(["b": binding], ["b"] + rest.dropFirst())
    }
}
