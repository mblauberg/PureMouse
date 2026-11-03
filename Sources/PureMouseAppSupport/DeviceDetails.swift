import Foundation
import PureMouseKit

/// What About This Mouse shows for one device, and the plain text Copy Details puts on the
/// pasteboard, both built from the daemon's status alone (the menu and Settings never open HID
/// devices). A fact the mouse does not report has no row. The unit ID and any serial number are
/// never in it: the status carries the first for the daemon's own use and this type leaves it out.
public struct DeviceDetails: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var label: String
        /// One line per entry; the Easy-Switch row has one per computer.
        public var lines: [Line]
        public var id: String { label }

        public init(label: String, lines: [Line]) {
            self.label = label
            self.lines = lines
        }

        public init(label: String, value: String) {
            self.init(label: label, lines: [Line(value)])
        }
    }

    public struct Line: Equatable, Sendable {
        public var text: String
        /// The computer this mouse is on now, among the Easy-Switch lines.
        public var current: Bool

        public init(_ text: String, current: Bool = false) {
            self.text = text
            self.current = current
        }
    }

    public var title: String
    public var rows: [Row]
    /// The PureMouse version that reported them, for a bug report.
    public var version: String?

    public init(_ device: Status.Device, version: String? = nil) {
        title = device.name
        self.version = version
        var rows: [Row] = []
        if let battery = Self.battery(device.battery) { rows.append(Row(label: "Battery", value: battery)) }
        rows.append(Row(label: "Connection", value: StatusText.connection(device)))
        if let hosts = Self.hosts(device.hosts) { rows.append(hosts) }
        if let firmware = device.firmware, !firmware.isEmpty { rows.append(Row(label: "Firmware", value: firmware)) }
        if let model = device.model, !model.isEmpty { rows.append(Row(label: "Model ID", value: model)) }
        self.rows = rows
    }

    /// "80%", "80%, charging", "Full" where the mouse gives a level only.
    static func battery(_ battery: Status.Device.Battery?) -> String? {
        guard let battery else { return nil }
        let level: String
        if let percent = battery.percent {
            level = "\(percent)%"
        } else {
            switch battery.level {
            case .full: level = "Full"
            case .good: level = "Good"
            case .low: level = "Low"
            case .critical: level = "Critical"
            }
        }
        return battery.charging ? level + ", charging" : level
    }

    /// "Computer 1" and what the mouse says of it: "This Mac" for the current one, else the name
    /// the computer gave it or "Not paired". Nil where the mouse reports no hosts.
    static func hosts(_ hosts: Status.Device.Hosts?) -> Row? {
        guard let hosts, !hosts.slots.isEmpty else { return nil }
        let lines = hosts.slots.enumerated().map { index, slot -> Line in
            let current = hosts.current == index
            var text = "Computer \(index + 1)"
            if current {
                text += " · This Mac"
            } else if let name = slot.name, !name.isEmpty {
                text += " · " + name
            } else if slot.paired == false {
                text += " · Not paired"
            }
            return Line(text, current: current)
        }
        return Row(label: "Easy-Switch", lines: lines)
    }

    /// The row shown on a device's line in General › Status: "Computer 1" for the current host.
    public static func currentHost(_ device: Status.Device) -> String? {
        guard let current = device.hosts?.current else { return nil }
        return "Computer \(current + 1)"
    }

    /// Plain text: the name, one line per fact, the computers indented, and the PureMouse version.
    public var copyText: String {
        var lines = [title]
        for row in rows {
            if row.lines.count == 1 {
                lines.append("\(row.label): \(row.lines[0].text)")
            } else {
                lines.append("\(row.label):")
                lines += row.lines.map { "  " + $0.text }
            }
        }
        if let version { lines.append("PureMouse: \(version == "dev" ? "dev build" : version)") }
        return lines.joined(separator: "\n")
    }
}
