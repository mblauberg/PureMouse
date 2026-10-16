import PureMouseKit

/// Words for the daemon's status, shared by the menu and Settings.
enum StatusText {
    static func connection(_ device: Status.Device) -> String {
        device.connection == .bluetooth ? "Bluetooth" : "USB receiver"
    }

    static func battery(_ battery: Status.Device.Battery?) -> String? {
        guard let battery else { return nil }
        if let percent = battery.percent {
            return battery.charging ? "Charging \(percent)%" : "Battery \(percent)%"
        }
        if battery.charging { return "Charging" }
        switch battery.level {
        case .full: return "Battery full"
        case .good: return "Battery good"
        case .low: return "Battery low"
        case .critical: return "Battery critical"
        }
    }

    /// "Bolt receiver · Battery 80%", or "Asleep".
    static func subtitle(_ device: Status.Device) -> String {
        guard device.online else { return "Asleep" }
        return ([connection(device)] + [battery(device.battery)].compactMap { $0 }).joined(separator: " · ")
    }

    /// The ⌥ detail line: "1,600 DPI · Wheel: ratchet · v0.2.0".
    static func detail(_ device: Status.Device, version: String) -> String {
        var parts: [String] = []
        if let dpi = device.dpi { parts.append(Format.dpi(dpi)) }
        if let mode = device.wheelMode { parts.append("Wheel: " + (mode == .ratchet ? "ratchet" : "free spin")) }
        parts.append(version == "dev" ? "dev build" : "v" + version)
        return parts.joined(separator: " · ")
    }

    /// VoiceOver label for the status item.
    @MainActor static func accessibilityLabel(model: AppModel) -> String {
        var parts = ["PureMouse"]
        if !model.daemonRunning {
            parts.append("off")
        } else if let device = model.primaryDevice {
            parts.append(device.name)
            if !device.online {
                parts.append("asleep")
            } else if let percent = device.battery?.percent {
                parts.append("battery \(percent) percent")
            }
            if model.paused {
                parts.append("paused")
            } else if model.status?.away == true {
                parts.append("on another Mac")
            }
        } else {
            parts.append("no mouse connected")
        }
        if model.needsAttention { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
