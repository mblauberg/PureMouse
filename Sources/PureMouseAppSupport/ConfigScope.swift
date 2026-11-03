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
    /// are not a placeholder, or `p` plus 4. The file may spell the entry's key in other case
    /// (Kit lowercases it); the tree finds the entry (`entryPrefix(for:)`), and `prefix` is where
    /// a new one goes.
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
    ///   entry cannot set it. The entry is the one Kit keeps for the key, whatever case the file
    ///   spells it in, and JSON `null` reads as absent on both sides, as Kit reads it.
    /// - `thumbWheel` is per key here, but its `action` also resets `step` and replaces `left` and
    ///   `right`, which only layering gets right: read the wheel with `thumbWheel(in:)`.
    /// - Any other scope has no wider one to fall back to: its own value, as `self[prefix + path]`.
    public func resolved(_ path: [String], in scope: ConfigScope) -> Any? {
        guard scope.deviceKey != nil else { return value(scope.prefix + path) }
        guard let section = path.first, Config.deviceSections.contains(section) else { return value(path) }
        let entry = deviceEntry(scope)
        if section == "buttons" { return resolvedButtons(Array(path.dropFirst()), device: entry) }
        let global = Self.clean(Self.lookup(root, path))
        guard let own = Self.clean(Self.lookup(entry, path)) else { return global }
        if path.count == 1, let own = own as? [String: Any], let global = global as? [String: Any] {
            return global.merging(own) { _, own in own }
        }
        return own
    }

    /// `resolved` as an integer, a double or a bool: nil when it is absent or another type (a
    /// bool is not a number here, nor the reverse), as `int`, `double` and `bool` read the tree.
    public func resolvedInt(_ path: [String], in scope: ConfigScope) -> Int? { Self.int(resolved(path, in: scope)) }
    public func resolvedDouble(_ path: [String], in scope: ConfigScope) -> Double? { Self.double(resolved(path, in: scope)) }
    public func resolvedBool(_ path: [String], in scope: ConfigScope) -> Bool? { Self.bool(resolved(path, in: scope)) }

    /// Whether `scope` itself sets the value at `path` (relative to the root, as `resolved`),
    /// rather than leaving it to the top level. Always false for the top level, and for a section a
    /// device entry cannot set. In a device, a button counts under whichever name or hex ID spells
    /// it, a primary click never counts (Kit ignores it), and a gesture direction counts when the
    /// mouse binds the direction itself or binds the control to something that is not a gesture
    /// (which hides the top level's directions).
    public func isOverridden(_ path: [String], in scope: ConfigScope) -> Bool {
        guard scope != .global else { return false }
        guard scope.deviceKey != nil else {
            var path = path
            if path.count >= 2, path[0] == "buttons" { path[1] = buttonKey(path[1], in: scope) }
            return value(scope.prefix + path) != nil
        }
        guard !path.isEmpty else { return self[entryPrefix(for: scope)] != nil }
        guard let section = path.first, Config.deviceSections.contains(section) else { return false }
        guard section == "buttons", path.count >= 2 else {
            return Self.lookup(Self.clean(deviceEntry(scope)) as? [String: Any] ?? [:], path) != nil
        }
        let buttons = deviceEntry(scope)["buttons"] as? [String: Any] ?? [:]
        let name = path[1]
        let binding: Any?
        if let cid = NamedButton.cid(forKey: name) {
            guard !Config.reservedControls.contains(cid) else { return false }
            binding = Self.binding(for: cid, in: buttons)?.value
        } else {
            // A name Kit has no control for cannot be set to Mouse Default: it is skipped either way.
            binding = buttons[name].flatMap { $0 is NSNull || Self.isNative($0) ? nil : $0 }
        }
        guard let binding else { return false }
        guard path.count >= 3 else { return true }
        // A name Kit has no control for is replaced whole, so any binding hides the top level's.
        guard NamedButton.cid(forKey: name) != nil, let gesture = Self.isGestureShape(binding) else { return true }
        return !(gesture[path[2]] is NSNull) && gesture[path[2]] != nil
    }

    /// The thumb wheel in `scope` as the daemon resolves it: the top level's keys, then the
    /// scope's on top (`Config.ThumbWheel.init(_:base:)`, where `action` resets the step and `left`
    /// and `right` replace one direction each).
    public func thumbWheel(in scope: ConfigScope) -> ThumbWheelState {
        let global = ThumbWheelState.initial.applying(Self.clean(self[["thumbWheel"]]) as? [String: Any])
        guard scope != .global else { return global }
        return global.applying(Self.clean(self[entryPrefix(for: scope) + ["thumbWheel"]]) as? [String: Any])
    }

    // MARK: Writing

    /// Sets the value at `path` in `scope`, or removes it when `value` is nil. Returns false, and
    /// changes nothing, when a device scope is asked for a key that is not one of Kit's device
    /// sections (`Config.deviceSections`): `apps`, `universalControl`, `notifications` and `name`
    /// are not written under a device.
    ///
    /// The first value written under a device creates its entry, with `name` (the mouse's name,
    /// else its key) written once; an entry that already exists keeps its own, whatever case its
    /// key is spelled in (`entryPrefix(for:)`). Removing the last override removes the entry, as a
    /// name-only entry says nothing, but an entry that holds any other key (one this app does not
    /// know) stays, `name` with it. Removing what is not there changes nothing. Within a section
    /// any key is written as given, known to Kit or not.
    @discardableResult
    public mutating func set(_ value: Any?, at path: [String], in scope: ConfigScope, name: String? = nil) -> Bool {
        guard let key = scope.deviceKey else {
            set(value, at: scope.prefix + path)
            return true
        }
        guard let section = path.first, Config.deviceSections.contains(section) else { return false }
        let entry = entryPrefix(for: scope)
        let target = entry + path
        if value == nil {
            guard contains(target) else { return true }
            removeKeepingShadow(at: target, entry: entry, name: name)
        } else {
            if !(self[entry] is [String: Any]) { set(name ?? entryName ?? key, at: entry + ["name"]) }
            set(value, at: target)
        }
        return true
    }

    /// Whether `entry` is the spelling the decoder keeps while the file spells the same mouse
    /// another way too (the last in sorted order): it then shadows the others.
    func shadowsOtherSpellings(_ entry: [String]) -> Bool {
        guard entry.count == 2, entry[0] == "devices" else { return false }
        let spellings = (self[["devices"]] as? [String: Any] ?? [:]).keys.filter { $0.lowercased() == entry[1].lowercased() }
        return spellings.count > 1 && spellings.max() == entry[1]
    }

    /// Removes the key at `target` inside the device entry `entry`. An entry emptied by it, or left
    /// holding only its `name`, goes, unless it shadows another spelling of the key: Kit then keeps
    /// this entry whole, and removing it would let the other spelling apply with every key it holds,
    /// so a name-only entry stays in its place.
    mutating func removeKeepingShadow(at target: [String], entry: [String], name: String? = nil) {
        let shadows = shadowsOtherSpellings(entry)
        set(nil, at: target)
        if shadows, self[entry] == nil { set(name ?? entryName ?? entry[1].lowercased(), at: entry + ["name"]) }
        pruneIfNameOnly(entry)
    }

    /// Removes a device entry that holds only its `name`, as a name says nothing without an override.
    /// Not when the file spells the key another way too and this is the spelling the decoder keeps
    /// (the last in sorted order): the entry then shadows the others, and removing it would let one
    /// of them apply, with every key it holds.
    mutating func pruneIfNameOnly(_ entry: [String]) {
        guard entry.count == 2, entry[0] == "devices", let rest = self[entry] as? [String: Any],
              rest.keys.allSatisfy({ $0 == "name" }) else { return }
        if shadowsOtherSpellings(entry) { return }
        set(nil, at: entry)
    }

    // MARK: Helpers

    /// Where `scope`'s own object lives. A device entry is found the way Kit finds it: the entry
    /// keys are lowercased, and when several spell one mouse the last in sorted order applies, so
    /// `MB03400000000` is the entry for `mb03400000000`. Without one, the scope's own prefix, where
    /// a first write creates it.
    func entryPrefix(for scope: ConfigScope) -> [String] {
        guard let key = scope.deviceKey, let devices = self[["devices"]] as? [String: Any],
              let raw = devices.keys.sorted().last(where: { $0.lowercased() == key }) else { return scope.prefix }
        return ["devices", raw]
    }

    private func deviceEntry(_ scope: ConfigScope) -> [String: Any] {
        self[entryPrefix(for: scope)] as? [String: Any] ?? [:]
    }

    /// The value at `path`, with JSON null read as absent, as the decoder reads it.
    private func value(_ path: [String]) -> Any? { Self.lookup(root, path) }

    /// `value` without the JSON nulls inside it (Kit skips a null key as if it were absent).
    private static func clean(_ value: Any?) -> Any? {
        guard let object = value as? [String: Any] else { return value is NSNull ? nil : value }
        return object.compactMapValues { $0 is NSNull ? nil : clean($0) }
    }

    private static func lookup(_ dict: [String: Any], _ path: [String]) -> Any? {
        var node: Any = dict
        for key in path {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        return node is NSNull ? nil : node
    }

    /// Whether `value` is `"default"` (`Config.Binding.nativeValue`): no binding, the mouse's own.
    private static func isNative(_ value: Any?) -> Bool {
        (value as? String) == Config.Binding.nativeValue
    }

    /// `value` as a trigger table, when the decoder reads it as one (`Gesture.isTable`).
    private static func isGestureShape(_ value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any], Gesture.isTable(object) else { return nil }
        return object
    }

    /// The binding for a control among the names `buttons` gives it: when several spell the same
    /// control, the decoder keeps the last in sorted order. A null binding is no binding here.
    private static func binding(for cid: UInt16, in buttons: [String: Any]) -> (name: String, value: Any)? {
        buttons.keys.sorted().last { NamedButton.cid(forKey: $0) == cid && !(buttons[$0] is NSNull) }.flatMap { name in
            buttons[name].map { (name, $0) }
        }
    }

    /// A binding as `resolved` returns it: no nulls, and a gesture that sets nothing is one whose
    /// directions all do nothing (Kit reads `{"up": null}` as a gesture).
    private static func normalised(_ binding: Any?) -> Any? {
        guard let binding else { return nil }
        let cleaned = clean(binding)
        if isGestureShape(binding) != nil, (cleaned as? [String: Any])?.isEmpty ?? true { return ["click": "none"] }
        return cleaned
    }

    /// `buttons` in a device: per control, the device's binding over the top level's, a table
    /// per trigger when both are tables (`Config.Binding.decode`, `Gesture.merge`). Reserved controls (the
    /// primary clicks) are never bound. `rest` is what follows `buttons`: nothing (all of them), a
    /// button name, then keys inside its binding. `device` is the raw entry: a `null` direction
    /// leaves the other side's, and a `null` binding is none.
    private func resolvedButtons(_ rest: [String], device: [String: Any]) -> Any? {
        let global = self[["buttons"]] as? [String: Any]
        let own = device["buttons"] as? [String: Any]
        guard let name = rest.first else {
            guard global != nil || own != nil else { return nil }
            var names: [String: String] = [:]  // a control, or an unknown name, to the name that spells it
            for buttons in [global ?? [:], own ?? [:]] {
                for key in buttons.keys.sorted() where !(buttons[key] is NSNull) {
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
                if Self.isNative(top) {
                    binding = nil  // Mouse Default: the top level's binding is cleared
                } else if let top = Self.isGestureShape(top), let base = Self.isGestureShape(base) {
                    binding = Gesture.merge(top, over: base)
                } else {
                    binding = top
                }
            } else {
                binding = base
            }
            if Self.isNative(binding) { binding = nil }  // "default" at the top level is no binding
        } else {
            binding = [own?[name], global?[name]].compactMap { $0 }.first { !($0 is NSNull) && !Self.isNative($0) }
        }
        guard let binding = Self.normalised(binding) else { return nil }
        guard rest.count > 1 else { return binding }
        // Triggers are a table's; any other binding has none (its other keys read as they are).
        if Gesture.triggers.contains(rest[1]), Self.isGestureShape(binding) == nil { return nil }
        return Self.lookup(["b": binding], ["b"] + rest.dropFirst())
    }
}
