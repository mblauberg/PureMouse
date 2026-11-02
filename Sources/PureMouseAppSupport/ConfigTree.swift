import Foundation

/// The config as a JSON tree. The app edits only the keys a control owns and keeps every other
/// key, including ones it does not know, so hand edits and the UI coexist (docs/companion.md).
public struct ConfigTree {
    var root: [String: Any]
    /// The name a device entry gets when a write creates it (`set(_:at:in:name:)` with no name):
    /// the mouse's, set by `AppModel` for the edit under way.
    var entryName: String?

    public init(_ root: [String: Any] = [:]) { self.root = root }

    /// Parses config JSON; an empty or whitespace-only file is an empty config.
    public init(data: Data) throws {
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) {
            root = [:]
            return
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigTreeError.notAnObject
        }
        root = object
    }

    /// Objects that mean something even when empty: `smoothScroll: {}` turns smooth scrolling on,
    /// at the top level and in a device entry (`devices.<key>.smoothScroll`).
    static func keptWhenEmpty(_ path: [String]) -> Bool {
        path == ["smoothScroll"] || (path.count == 3 && path[0] == "devices" && path[2] == "smoothScroll")
    }

    public subscript(path: [String]) -> Any? {
        var node: Any = root
        for key in path {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        return node
    }

    public func contains(_ path: [String]) -> Bool { self[path] != nil }

    /// Sets the value at `path`, or removes it when `value` is nil. Intermediate values that are
    /// not objects are replaced by objects. Objects left empty by a removal are pruned, except
    /// those `keptWhenEmpty` names. Removing a key that is not there changes nothing, so it cannot
    /// prune an empty object it passes through (which `changes(to:)` would then record).
    public mutating func set(_ value: Any?, at path: [String]) {
        guard !path.isEmpty, value != nil || contains(path) else { return }
        root = Self.setting(value, at: path[...], in: root, prefix: [])
    }

    private static func setting(_ value: Any?, at path: ArraySlice<String>, in dict: [String: Any],
                                prefix: [String]) -> [String: Any] {
        var dict = dict
        let key = path.first!
        if path.count == 1 {
            dict[key] = value
            return dict
        }
        let child = dict[key] as? [String: Any]
        if child == nil, value == nil { return dict }
        let updated = setting(value, at: path.dropFirst(), in: child ?? [:], prefix: prefix + [key])
        if updated.isEmpty, !keptWhenEmpty(prefix + [key]) {
            dict[key] = nil
        } else {
            dict[key] = updated
        }
        return dict
    }

    // MARK: Typed reads

    public func bool(_ path: [String]) -> Bool? { Self.bool(self[path]) }
    public func double(_ path: [String]) -> Double? { Self.double(self[path]) }
    public func int(_ path: [String]) -> Int? { Self.int(self[path]) }

    static func bool(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, JSON.isBool(value) else { return nil }
        return value.boolValue
    }

    static func double(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, !JSON.isBool(value) else { return nil }
        return value.doubleValue
    }

    static func int(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, !JSON.isBool(value) else { return nil }
        // Whole numbers and big ones (NSDecimalNumber) read exactly from their digits.
        if value is NSDecimalNumber || !JSON.isFloatingPoint(value) { return Int(value.stringValue) }
        let double = value.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    public func string(_ path: [String]) -> String? { self[path] as? String }

    public func data() -> Data { JSON.encode(root) }

    // MARK: Changes

    /// One key set to a value, or removed (nil).
    public struct Change {
        public let path: [String]
        public let value: Any?

        public init(path: [String], value: Any?) {
            self.path = path
            self.value = value
        }
    }

    /// The keys `after` changed relative to `self`, as leaf-level changes. Replayed with `apply`
    /// onto a newer tree, they change only those keys, so a hand edit elsewhere survives. A new
    /// object is added key by key too, so it merges into one a hand edit added meanwhile (an empty
    /// one is set whole). An object that disappeared is removed key by key (it may only have been
    /// pruned as empty), except one that means something when empty (`keptWhenEmpty`) or that was
    /// empty, which is removed whole. A device entry that disappeared leaves its `name` out of
    /// that: `apply` removes the name with the entry's last other key, so an entry a hand edit gave
    /// other keys meanwhile keeps its name.
    func changes(to after: ConfigTree) -> [Change] {
        var out: [Change] = []
        Self.diff(root, after.root, path: [], vanishing: false, into: &out)
        return out
    }

    /// Replays `changes`. A device entry left holding only its `name` by a removal goes too, as
    /// `set(_:at:in:name:)` removes it, since a name says nothing without an override.
    mutating func apply(_ changes: [Change]) {
        for change in changes {
            let removing = change.value == nil && contains(change.path)
            if removing, change.path.count > 2, change.path[0] == "devices" {
                removeKeepingShadow(at: change.path, entry: Array(change.path.prefix(2)))
            } else {
                set(change.value, at: change.path)
            }
        }
    }

    private static func diff(_ before: [String: Any], _ after: [String: Any], path: [String],
                             vanishing: Bool, into out: inout [Change]) {
        for key in Set(before.keys).union(after.keys).sorted() {
            let path = path + [key]
            if vanishing, path.count == 3, path[0] == "devices", key == "name" { continue }
            switch (before[key], after[key]) {
            case let (old as [String: Any], new as [String: Any]):
                diff(old, new, path: path, vanishing: false, into: &out)
            case let (old as [String: Any], nil) where !old.isEmpty && !keptWhenEmpty(path):
                diff(old, [:], path: path, vanishing: path.count == 2 && path[0] == "devices" && old.keys.contains { $0 != "name" }, into: &out)
            case let (nil, new as [String: Any]) where !new.isEmpty:
                diff([:], new, path: path, vanishing: false, into: &out)
            case let (old?, new) where new == nil || JSON.encode(old) != JSON.encode(new!):
                out.append(Change(path: path, value: new))
            case let (nil, new?):
                out.append(Change(path: path, value: new))
            default:
                break
            }
        }
    }
}

enum ConfigTreeError: Error, CustomStringConvertible {
    case notAnObject
    var description: String { "The config must be a JSON object: { … }" }
}

/// A small JSON writer: two-space indents, sorted keys, `"key": value`, and the shortest decimal
/// that round-trips each number (`0.7`, not `0.69999999999999996` as JSONSerialization writes).
enum JSON {
    static func encode(_ value: Any) -> Data {
        var out = ""
        write(value, indent: 0, to: &out)
        out += "\n"
        return Data(out.utf8)
    }

    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// A binary floating-point number (not a whole number, and not an exact NSDecimalNumber).
    static func isFloatingPoint(_ number: NSNumber) -> Bool {
        guard !(number is NSDecimalNumber) else { return false }
        let type = String(cString: number.objCType)
        return type == "d" || type == "f"
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    private static func write(_ value: Any, indent: Int, to out: inout String) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closePad = String(repeating: "  ", count: indent)
        switch value {
        case let dict as [String: Any]:
            if dict.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, key) in dict.keys.sorted().enumerated() {
                out += pad + quoted(key) + ": "
                write(dict[key]!, indent: indent + 1, to: &out)
                out += i == dict.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        case let array as [Any]:
            if array.isEmpty { out += "[]"; return }
            // Arrays of plain numbers stay on one line ([800, 1600, 3200]).
            if array.allSatisfy({ $0 is NSNumber }) {
                out += "[" + array.map { scalar($0) }.joined(separator: ", ") + "]"
                return
            }
            out += "[\n"
            for (i, element) in array.enumerated() {
                out += pad
                write(element, indent: indent + 1, to: &out)
                out += i == array.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        default:
            out += scalar(value)
        }
    }

    private static func scalar(_ value: Any) -> String {
        switch value {
        case let string as String: return quoted(string)
        case let number as NSNumber:
            if isBool(number) { return number.boolValue ? "true" : "false" }
            // Doubles get their shortest round-trip form. Integers, and numbers too big or too
            // precise for a double (JSONSerialization reads those as NSDecimalNumber), keep
            // their exact digits.
            if isFloatingPoint(number) { return self.number(number.doubleValue) }
            return number.stringValue
        case is NSNull: return "null"
        case let bool as Bool: return bool ? "true" : "false"
        case let int as Int: return String(int)
        case let double as Double: return number(double)
        default: return "null"
        }
    }

    static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
