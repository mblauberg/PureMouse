import Foundation

// Per-device settings: `"devices": {"<device key>": {"dpi": …, "buttons": …}}`. Each entry is
// decoded on top of the top-level settings and the top-level `apps` merged onto that, so an entry
// names only what differs for that mouse. Precedence: top level, then the device, then the app.
// `apps`, `universalControl` and `notifications` stay top level only.

extension Config {
    /// The sections a device entry may set. An entry may also hold a `name` for the user's own
    /// reference, which is ignored; anything else is ignored with a warning. Public so the menu
    /// bar app's `ConfigTree` writes under a device only what the decoder reads.
    public static let deviceSections: Set = [
        "dpi", "dpiPresets", "scrollWheel", "thumbWheel", "smoothScroll", "buttons", "gesture",
    ]

    /// The settings for the mouse with this device key (lowercase, as `deviceKey` gives it): its
    /// entry, else the top level.
    public func forDevice(_ key: String?) -> Config {
        key.flatMap { devices[$0] } ?? self
    }

    /// The global and per-app scopes of the top level and of every device entry: whatever any
    /// mouse may use, for decisions that cover them all, such as permissions.
    public var everyScope: [AppSettings] {
        ([self] + devices.keys.sorted().compactMap { devices[$0] }).flatMap { config in
            [config.global] + config.apps.keys.sorted().compactMap { config.apps[$0] }
        }
    }

    /// A mouse's device key: `m` and its 0x0003 model ID in 12 lowercase hex digits, or, without a
    /// usable model ID (absent, or a placeholder), `p` and its product ID in 4.
    public static func deviceKey(modelID: [UInt8]?, productID: UInt16?) -> String? {
        if let modelID, modelID.count == 6, let hex = identityHex(modelID) { return "m" + hex }
        return productID.map { "p" + String(format: "%04x", $0) }
    }

    /// A 0x0003 identity field (model ID, unit ID) in lowercase hex, or nil for the placeholders
    /// a mouse reports for one it lacks: all zeros or all 0xFF.
    public static func identityHex(_ bytes: [UInt8]) -> String? {
        guard !bytes.allSatisfy({ $0 == 0 }), !bytes.allSatisfy({ $0 == 0xFF }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `key` is one `deviceKey` gives: `m` plus 12 lowercase hex digits that are not a
    /// placeholder, or `p` plus 4.
    public static func isDeviceKey(_ key: String) -> Bool {
        let digits = Array(key.dropFirst())
        switch key.first {
        case "m":
            guard digits.count == 12 else { return false }
            let bytes = stride(from: 0, to: 12, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
            return deviceKey(modelID: bytes, productID: nil) == key
        case "p":
            return digits.count == 4 && UInt16(String(digits), radix: 16).flatMap { deviceKey(modelID: nil, productID: $0) } == key
        default:
            return false
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
            for section in entry.allKeys.map(\.stringValue).sorted()
            where section != "name" && !Self.deviceSections.contains(section) {
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
