import Foundation

/// The config as a JSON tree. The app edits only the keys a control owns and keeps every other
/// key, including ones it does not know, so hand edits and the UI coexist (docs/companion.md).
struct ConfigTree {
    var root: [String: Any]

    init(_ root: [String: Any] = [:]) { self.root = root }

    /// Parses config JSON; an empty or whitespace-only file is an empty config.
    init(data: Data) throws {
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) {
            root = [:]
            return
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigTreeError.notAnObject
        }
        root = object
    }

    /// Objects that mean something even when empty: `smoothScroll: {}` turns smooth scrolling on.
    static let keptWhenEmpty: Set<String> = ["smoothScroll"]

    subscript(path: [String]) -> Any? {
        var node: Any = root
        for key in path {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        return node
    }

    func contains(_ path: [String]) -> Bool { self[path] != nil }

    /// Sets the value at `path`, or removes it when `value` is nil. Intermediate values that are
    /// not objects are replaced by objects. Objects left empty by a removal are pruned, except
    /// those in `keptWhenEmpty`.
    mutating func set(_ value: Any?, at path: [String]) {
        guard !path.isEmpty else { return }
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
        let childPath = (prefix + [key]).joined(separator: ".")
        if updated.isEmpty, !keptWhenEmpty.contains(childPath) {
            dict[key] = nil
        } else {
            dict[key] = updated
        }
        return dict
    }

    // MARK: Typed reads

    func bool(_ path: [String]) -> Bool? {
        guard let value = self[path] as? NSNumber, JSON.isBool(value) else { return nil }
        return value.boolValue
    }

    func double(_ path: [String]) -> Double? {
        guard let value = self[path] as? NSNumber, !JSON.isBool(value) else { return nil }
        return value.doubleValue
    }

    func int(_ path: [String]) -> Int? {
        guard let value = double(path), value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    func string(_ path: [String]) -> String? { self[path] as? String }

    func data() -> Data { JSON.encode(root) }
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
            let type = String(cString: number.objCType)
            if type == "d" || type == "f" { return self.number(number.doubleValue) }
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
