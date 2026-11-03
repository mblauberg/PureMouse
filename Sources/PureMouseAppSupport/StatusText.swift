import Foundation
import PureMouseKit

/// Words for the daemon's status, shared by the menu and Settings.
public enum StatusText {
    static func connection(_ device: Status.Device) -> String {
        device.connection == .bluetooth ? "Bluetooth" : "USB receiver"
    }

    public static func battery(_ battery: Status.Device.Battery?) -> String? {
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

    public static let applying = "Applying settings…"
    public static let notApplied = "Settings not applied"

    /// "USB receiver · Battery 80%", "Applying settings…", "Settings not applied" or "Asleep". The
    /// applied state speaks only while it is not simply applied: no line says all is well.
    public static func subtitle(_ device: Status.Device) -> String {
        switch device.applied?.state {
        case .applying: return applying
        case .notApplied: return notApplied
        case .applied, nil: break
        }
        guard device.online else { return "Asleep" }
        return ([connection(device)] + [battery(device.battery)].compactMap { $0 }).joined(separator: " · ")
    }

    /// The ⌥ detail line: "1,600 DPI · Wheel: ratchet · Settings applied at 09:14 · v0.2.0".
    public static func detail(_ device: Status.Device, version: String,
                              locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let dpi = device.dpi { parts.append(Format.dpi(dpi)) }
        if let mode = device.wheelMode { parts.append("Wheel: " + (mode == .ratchet ? "ratchet" : "free spin")) }
        if let applied = device.applied, applied.state == .applied, let at = applied.at {
            parts.append("Settings applied at " + time(at, locale: locale, timeZone: timeZone))
        }
        parts.append(version == "dev" ? "dev build" : "v" + version)
        return parts.joined(separator: " · ")
    }

    /// "09:14": the hour and minute in the person's own style.
    public static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// A device's line in General › Status: its subtitle, then the computer it is on where the
    /// mouse says, "USB receiver · Battery 80% · Computer 1". Where the settings are not applied the
    /// line keeps the connection, "Settings not applied · USB receiver": the row has room, and the
    /// facts it would otherwise show are still true.
    public static func row(_ device: Status.Device) -> String {
        if device.applied?.state == .notApplied { return [notApplied, connection(device)].joined(separator: " · ") }
        var text = subtitle(device)
        if device.online, device.applied?.state != .applying, device.applied?.state != .notApplied,
           let host = DeviceDetails.currentHost(device) { text += " · " + host }
        return text
    }
}
