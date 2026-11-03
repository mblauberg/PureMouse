import Foundation
import PureMouseKit

extension NamedButton {
    /// What a pane calls the control a config key names: the button's own label, else Kit's name
    /// for its control ID ("DPI button" for 0x00FD), else a plain `Button N` (N the control ID in
    /// decimal, so it is the same wherever it shows). A key that is neither a button nor a control
    /// ID is `Other button`.
    public static func title(forKey key: String) -> String {
        if let named = NamedButton(rawValue: key) { return named.label }
        guard let cid = cid(forKey: key) else { return "Other button" }
        return ControlNames.name(cid) ?? "Button \(cid)"
    }
}
