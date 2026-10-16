import CoreGraphics
import PureMouseKit

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

/// The buttons a session holds down: the controls last reported pressed, the gesture button
/// with the gesture it was bound to when pressed, and native clicks posted for buttons bound
/// only in other apps. `drop` lets go of all of it, posting the native releases, whenever the
/// mouse's own releases may never arrive: link down, reconnect, reload, pause, quit.
struct HeldButtons {
    private(set) var pressed: [UInt16] = []
    private(set) var gesture: (cid: UInt16, gesture: Config.Binding.Gesture)?
    private(set) var native: Set<UInt16> = []
    private let post: (UInt16, Bool) -> Bool

    init(post: @escaping (UInt16, Bool) -> Bool = { NativeButton.post($0, down: $1) }) {
        self.post = post
    }

    /// Takes the controls now down; returns those newly pressed and those let go.
    mutating func update(_ cids: [UInt16]) -> (pressed: [UInt16], released: [UInt16]) {
        defer { pressed = cids }
        return (cids.filter { !pressed.contains($0) }, pressed.filter { !cids.contains($0) })
    }

    /// Starts holding a gesture; false while another gesture button is held.
    mutating func holdGesture(_ cid: UInt16, _ binding: Config.Binding.Gesture) -> Bool {
        guard gesture == nil else { return false }
        gesture = (cid, binding)
        return true
    }

    /// Forgets the held gesture, so letting it go does nothing.
    mutating func forgetGesture() {
        gesture = nil
    }

    /// Presses `cid` as an ordinary mouse button, if it has one.
    mutating func clickNatively(_ cid: UInt16) {
        if post(cid, true) { native.insert(cid) }
    }

    /// Lets go of `cid`: a native click is released; the gesture it held is returned.
    mutating func release(_ cid: UInt16) -> Config.Binding.Gesture? {
        if native.remove(cid) != nil {
            _ = post(cid, false)
            return nil
        }
        guard let held = gesture, held.cid == cid else { return nil }
        gesture = nil
        return held.gesture
    }

    /// Lets go of everything without acting on it.
    mutating func drop() {
        for cid in native { _ = post(cid, false) }
        native = []
        pressed = []
        gesture = nil
    }
}
