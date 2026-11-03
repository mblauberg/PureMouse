import Foundation
import PureMouseKit

/// The default set as Settings sees it (docs/configuration.md, "Defaults"). Kit's decoder lays the
/// file over `Config.defaultSetJSON`; the tree the panes read is laid over the same text, so what a
/// pane shows is what the daemon runs. Writes go to the file as the keys they change (`ConfigStore`),
/// and a file that leaves a key out takes its value from here.
extension ConfigTree {
    /// The default set as a tree.
    nonisolated(unsafe) public static let defaults: ConfigTree = {
        guard let tree = try? ConfigTree(data: Data(Config.defaultSetJSON.utf8)) else {
            preconditionFailure("The default set is not a JSON object")
        }
        return tree
    }()

    /// This tree laid over the default set: the tree the daemon would decode. Applying it to a
    /// tree that is laid over it already changes nothing.
    public func layered() -> ConfigTree {
        var out = ConfigTree(Self.lay(root, over: Self.defaults.root, path: []))
        out.entryName = entryName
        return out
    }

    /// Whether `path` holds a value the default set does not: set by the user, not just in effect.
    public func holdsBeyondDefaults(_ path: [String]) -> Bool {
        guard let value = self[path] else { return false }
        guard let base = Self.defaults[path] else { return true }
        return JSON.encode(value) != JSON.encode(base)
    }

    /// The default set's binding for a control (`Config.defaults`), if it has one.
    static func defaultBinding(for button: String) -> Any? {
        guard let cid = NamedButton.cid(forKey: button) else { return nil }
        return defaults[["buttons"]].flatMap { $0 as? [String: Any] }
            .flatMap { buttons in buttons.keys.sorted().last { NamedButton.cid(forKey: $0) == cid }.flatMap { buttons[$0] } }
    }

    /// `top` over `base`, key by key. Under `buttons`, a name replaces the default set's binding
    /// for the control it spells, whatever the spelling, and a gesture layers per direction (as
    /// `Config.decodeButtons` does). A `null` leaves what is underneath, as the decoder reads it.
    private static func lay(_ top: [String: Any], over base: [String: Any], path: [String]) -> [String: Any] {
        if path == ["buttons"] { return layButtons(top, over: base) }
        var out = base
        for (key, value) in top {
            if value is NSNull, out[key] != nil { continue }
            if let over = value as? [String: Any], let under = out[key] as? [String: Any] {
                out[key] = lay(over, over: under, path: path + [key])
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// `buttons`: every name the file gives a control replaces the names the default set had for
    /// it, whatever the spelling, and a gesture object layers per direction on the default set's
    /// gesture for that control, as `Config.decodeButtons` does with the bindings before the file.
    private static func layButtons(_ top: [String: Any], over base: [String: Any]) -> [String: Any] {
        var out = base
        for name in top.keys.sorted() {
            guard let value = top[name] else { continue }
            if value is NSNull {
                if out[name] == nil { out[name] = value }
                continue
            }
            guard let cid = NamedButton.cid(forKey: name) else {
                out[name] = value
                continue
            }
            let underneath = base.keys.sorted().last { NamedButton.cid(forKey: $0) == cid && !(base[$0] is NSNull) }
                .flatMap { base[$0] }
            for other in base.keys where NamedButton.cid(forKey: other) == cid { out[other] = nil }
            if let over = value as? [String: Any], let under = underneath as? [String: Any],
               isGesture(over), isGesture(under) {
                out[name] = lay(over, over: under, path: ["buttons", name])
            } else {
                out[name] = value
            }
        }
        return out
    }

    private static func isGesture(_ object: [String: Any]) -> Bool {
        !object.isEmpty && object.keys.allSatisfy(Gesture.directions.contains)
    }
}
