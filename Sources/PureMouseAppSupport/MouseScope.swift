import Foundation
import PureMouseKit

/// A mouse the Mouse tab's pop-up can choose (docs/configuration.md, "Settings and per-mouse values").
public struct KnownMouse: Equatable, Identifiable, Sendable {
    /// The mouse's device key: its entry under `devices`.
    public let key: String
    public let name: String
    /// The daemon lists it now (connected or asleep), as against a mouse only `devices` names.
    public let reported: Bool

    public var id: String { key }
}

/// The scope a pane edits and the name a first write gives the mouse's entry.
public struct ScopeTarget: Equatable, Sendable {
    public let scope: ConfigScope
    /// The mouse's name, written once when the first value creates its entry.
    public let name: String?

    public init(scope: ConfigScope, name: String? = nil) {
        self.scope = scope
        self.name = name
    }

    public static let allMice = ScopeTarget(scope: .global)
}

/// Which mice Settings knows, whether it offers the choice, and which reported mice decide what a
/// scope shows.
public enum MouseScope {
    /// Shown for a config entry that has no `name` and no mouse reporting its key.
    public static func unknownName(_ key: String) -> String { "Unknown mouse \(key)" }

    /// The mice to choose from: those the daemon reports with a device key (one entry per key, as
    /// mice of one model share their settings), then the `devices` entries no reported mouse has,
    /// named from `name`, else "Unknown mouse <key>".
    public static func known(devices: [Status.Device], config: ConfigTree) -> [KnownMouse] {
        var seen = Set<String>()
        var mice: [KnownMouse] = []
        for device in devices {
            guard let key = device.model?.lowercased(), Config.isDeviceKey(key), seen.insert(key).inserted else { continue }
            mice.append(KnownMouse(key: key, name: device.name, reported: true))
        }
        let names = config.deviceEntryNames
        for key in config.deviceEntries.keys.sorted() where seen.insert(key).inserted {
            mice.append(KnownMouse(key: key, name: names[key] ?? unknownName(key), reported: false))
        }
        return mice
    }

    /// The pop-up shows with two or more mice known, or with any `devices` entry in the config: a
    /// lone mouse with an entry gets it too, since otherwise the entry's overrides would shadow
    /// edits made under All Mice with nothing to show it.
    public static func offersChoice(known: [KnownMouse], config: ConfigTree) -> Bool {
        known.count >= 2 || !config.deviceEntries.isEmpty
    }

    /// The mice that decide which controls show in `scope`, judged by what they report
    /// (`ControlAvailability`). Empty when nothing can be judged, which leaves every control
    /// shown and editable:
    /// - PureMouse is off or paused;
    /// - one mouse: the mouse is not connected (a mouse asleep may have the feature);
    /// - All Mice: some known mouse is not connected, or a `devices` entry names a mouse that is
    ///   not reported, since either may have the feature. Otherwise every connected mouse, and a
    ///   control shows if any of them offers it.
    /// A capability a mouse leaves out is unknown and counts as offered (`Status.Device.offers`).
    public static func deciding(devices: [Status.Device], config: ConfigTree, scope: ConfigScope,
                                running: Bool, paused: Bool) -> [Status.Device] {
        guard running, !paused else { return [] }
        if let key = scope.deviceKey {
            let mine = devices.filter { $0.model?.lowercased() == key }
            return mine.contains(where: \.online) ? mine.filter(\.online) : []
        }
        guard devices.allSatisfy(\.online) else { return [] }
        let reported = Set(devices.compactMap { $0.model?.lowercased() })
        guard config.deviceEntries.keys.allSatisfy(reported.contains) else { return [] }
        return devices
    }

    /// The reported mice a scope describes, connected or not: every mouse for All Mice, the ones
    /// with this key for one. Which controls the Buttons list offers follows from them.
    public static func described(devices: [Status.Device], scope: ConfigScope) -> [Status.Device] {
        guard let key = scope.deviceKey else { return devices }
        return devices.filter { $0.model?.lowercased() == key }
    }
}

extension ConfigTree {
    /// The `name` of each `devices` entry that has one, by lowercase key.
    public var deviceEntryNames: [String: String] {
        guard let devices = self[["devices"]] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for raw in devices.keys.sorted() {
            if let name = (devices[raw] as? [String: Any])?["name"] as? String { out[raw.lowercased()] = name }
        }
        return out
    }
}
