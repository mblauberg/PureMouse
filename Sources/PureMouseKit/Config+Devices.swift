import Foundation

// Per-device settings: `"devices": {"<device key>": {"dpi": …, "buttons": …}}`. Each entry is
// decoded on top of the top-level settings and the top-level `apps` merged onto that, so an entry
// names only what differs for that mouse. Precedence: top level, then the device, then the app.
// `apps`, `universalControl` and `notifications` stay top level only.

extension Config {
    /// The sections a device entry may set; anything else in an entry is ignored with a warning.
    /// `name` is informational (which mouse the key is), and the daemon ignores it.
    public static let deviceSections: Set = [
        "dpi", "dpiPresets", "scrollWheel", "thumbWheel", "smoothScroll", "buttons", "gesture", "name",
    ]

    /// The settings for the mouse with this device key: its entry, else the top level.
    public func forDevice(_ key: String?) -> Config {
        key.flatMap { devices[$0.lowercased()] } ?? self
    }

    /// The global and per-app scopes of the top level and of every device entry: whatever any
    /// mouse may use, for decisions that cover them all (permissions, the adoption gate).
    public var everyScope: [AppSettings] {
        ([self] + devices.keys.sorted().compactMap { devices[$0] }).flatMap { config in
            [config.global] + config.apps.keys.sorted().compactMap { config.apps[$0] }
        }
    }

    /// A mouse's device key: `m` and its 0x0003 model ID in 12 lowercase hex digits, or, without a
    /// usable model ID (absent, or all zeros or all 0xFF), `p` and its product ID in 4.
    public static func deviceKey(modelID: [UInt8]?, productID: UInt16?) -> String? {
        if let modelID, modelID.count == 6, !modelID.allSatisfy({ $0 == 0 }), !modelID.allSatisfy({ $0 == 0xFF }) {
            return "m" + modelID.map { String(format: "%02x", $0) }.joined()
        }
        return productID.map { "p" + String(format: "%04x", $0) }
    }

    /// Whether `key` has the shape `deviceKey` gives: `m` plus 12 lowercase hex digits, not all
    /// zeros or all `f`, or `p` plus 4.
    public static func isDeviceKey(_ key: String) -> Bool {
        let digits = key.dropFirst()
        guard digits.allSatisfy("0123456789abcdef".contains) else { return false }
        switch key.first {
        case "m": return digits.count == 12 && digits.contains { $0 != "0" } && digits.contains { $0 != "f" }
        case "p": return digits.count == 4
        default: return false
        }
    }

    /// Resolves each entry of `c` onto the top level decoded so far, then `apps` onto that. Every
    /// entry is decoded, so a bad value fails the load whatever its key, but only entries with a
    /// device key are kept. Warnings are collected here, prefixed with the entry.
    mutating func decodeDevices(_ c: KeyedDecodingContainer<AnyKey>, apps: KeyedDecodingContainer<AnyKey>?) throws {
        var top = self
        top.apps = [:]
        top.warnings = []
        top.unknownButtons = []
        for key in c.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            let name = key.stringValue
            let folded = name.lowercased()
            let valid = Self.isDeviceKey(folded)
            if !valid { warnings.append("devices.\(name): not a device key; it matches no device") }
            let entry = try c.nestedContainer(keyedBy: AnyKey.self, forKey: key)
            for section in entry.allKeys.map(\.stringValue).sorted() where !Self.deviceSections.contains(section) {
                warnings.append("devices.\(name).\(section) is not a per-device setting; ignored")
            }
            _ = try entry.decodeIfPresent(String.self, forKey: AnyKey("name"))
            var device = top
            try device.decodeSections(entry)
            warnings += device.warnings.map { "devices.\(name).\($0)" }
            warnings += device.unknownButtons.map { "devices.\(name).buttons: unknown button '\($0)'" }
            device.warnings = []
            device.unknownButtons = []
            if let apps {
                try device.decodeApps(apps)
                device.warnings = []  // the top level reported them
            }
            guard valid else { continue }
            if devices[folded] != nil { warnings.append("devices.\(name) repeats another entry; the last one applies") }
            devices[folded] = device
        }
    }
}
