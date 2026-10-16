import CoreGraphics

/// The ordinary mouse-button click a diverted button stands for, for a button bound in some apps
/// but not everywhere: elsewhere it still clicks as it does without PureMouse.
enum NativeButton {
    /// macOS button numbers: wheel press 2, back 3, forward 4. Other controls have no click.
    static func number(for cid: UInt16) -> Int64? {
        switch cid {
        case 0x0052: 2
        case 0x0053: 3
        case 0x0056: 4
        default: nil
        }
    }

    /// Posts the button's press or release at the pointer. Returns false for a control without
    /// a click.
    @discardableResult
    static func post(_ cid: UInt16, down: Bool) -> Bool {
        guard let number = number(for: cid), let button = CGMouseButton(rawValue: UInt32(number)) else { return false }
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                                  mouseType: down ? .otherMouseDown : .otherMouseUp,
                                  mouseCursorPosition: location, mouseButton: button) else { return true }
        event.setIntegerValueField(.mouseEventButtonNumber, value: number)
        event.post(tap: .cghidEventTap)
        return true
    }
}
