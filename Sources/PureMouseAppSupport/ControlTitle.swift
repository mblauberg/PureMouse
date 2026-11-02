import Foundation
import PureMouseKit

extension NamedButton {
    /// What a pane calls the control a config key names: the button's own label, else Kit's name
    /// for its control ID ("DPI button" for 0x00FD), else `Control 0x00FD`. A key that is neither a
    /// button nor a control ID shows as `Control <key>`.
    public static func title(forKey key: String) -> String {
        if let named = NamedButton(rawValue: key) { return named.label }
        guard let cid = cid(forKey: key) else { return "Control \(key)" }
        return ControlNames.name(cid) ?? "Control " + String(format: "0x%04X", cid)
    }
}
