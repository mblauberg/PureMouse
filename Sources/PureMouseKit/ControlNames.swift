import Foundation

/// Names for the control IDs a HID++ mouse reports (feature 0x1B04 control IDs), so a log line or
/// the menu can say "DPI button" instead of "Control 253". The IDs are Logitech's, as catalogued by
/// Solaar (`special_keys.py`); the names are PureMouse's own. Mouse controls only.
///
/// This is not the config vocabulary: `Config.Button` names the few controls a config can spell as
/// words, and any control can be spelled as a hex ID. A control missing here still works.
public enum ControlNames {
    /// The name of control `cid`, or nil when it is not in the table.
    public static func name(_ cid: UInt16) -> String? {
        table[cid]
    }

    /// `name (0x00fd)` for a control in the table, `0x00fd` for one that is not: how the daemon's
    /// log lines and the menu refer to a control.
    public static func describe(_ cid: UInt16) -> String {
        let hex = String(format: "0x%04x", cid)
        guard let name = name(cid) else { return hex }
        return "\(name) (\(hex))"
    }

    private static let table: [UInt16: String] = {
        var names: [UInt16: String] = [
            0x0050: "Left button",
            0x0051: "Right button",
            0x0052: "Wheel click",
            0x0053: "Back",
            0x0054: "Back (system)",
            0x0055: "Back (Alt+arrow)",
            0x0056: "Forward",
            0x0057: "Forward (system)",
            0x0058: "Forward (Alt+arrow)",
            0x0059: "Button 6",
            0x005A: "Wheel left (button 7)",
            0x005B: "Wheel tilt left",
            0x005C: "Wheel right (button 8)",
            0x005D: "Wheel tilt right",
            0x00C3: "Gesture button",
            0x00C4: "Top button",
            0x00CE: "Back (multi-platform)",
            0x00CF: "Forward (multi-platform)",
            0x00D0: "Gesture button (multi-platform)",
            0x00D7: "Virtual gesture button",
            0x00D8: "Cursor button (long press)",
            0x00ED: "DPI change",
            0x00FD: "DPI button",
            0x0102: "Left and right click",
            0x01A0: "Thumb panel",
        ]
        // Buttons 9 to 24 are consecutive IDs.
        for number in 9...24 { names[UInt16(0x005E + number - 9)] = "Button \(number)" }
        return names
    }()
}
