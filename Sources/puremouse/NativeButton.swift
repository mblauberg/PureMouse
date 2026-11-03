import CoreGraphics
import PureMouseKit

/// The ordinary mouse-button click a diverted button stands for, for a button bound in some apps
/// but not everywhere: elsewhere it still clicks as it does without PureMouse.
enum NativeButton {
    /// macOS button numbers (`Config.nativeBehaviour`): wheel press 2, back 3, forward 4. Other
    /// controls have no click.
    static func number(for cid: UInt16) -> Int64? {
        if case .click(let button)? = Config.nativeBehaviour(of: cid) { Int64(button) } else { nil }
    }

    /// Posts a complete middle click at the pointer, using the same CGEvent path as native buttons.
    static func postMiddleClick() {
        _ = postMiddle(down: true)
        _ = postMiddle(down: false)
    }

    /// Posts the middle button's press or release at the pointer, so a held middle click can drag.
    @discardableResult
    static func postMiddle(down: Bool) -> Bool { post(number: 2, down: down) }

    /// Posts the left button's press or release at the pointer, for Drag Lock: while it is down,
    /// moving the mouse drags.
    @discardableResult
    static func postLeft(down: Bool) -> Bool {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                                  mouseType: down ? .leftMouseDown : .leftMouseUp,
                                  mouseCursorPosition: location, mouseButton: .left) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Posts the button's press or release at the pointer. Returns false for a control without
    /// a click.
    @discardableResult
    static func post(_ cid: UInt16, down: Bool) -> Bool {
        guard let number = number(for: cid) else { return false }
        return post(number: number, down: down)
    }

    @discardableResult
    private static func post(number: Int64, down: Bool) -> Bool {
        guard let button = CGMouseButton(rawValue: UInt32(number)) else { return false }
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
/// with the gesture it was bound to when pressed, native clicks posted for buttons bound
/// only in other apps, middle clicks held down for buttons bound to Middle Click, and the left
/// button Drag Lock holds. `drop` lets go of all of it, posting the releases, whenever the
/// mouse's own releases may never arrive: link down, reconnect, reload, pause, quit, a hand-off.
struct HeldButtons {
    private(set) var pressed: [UInt16] = []
    private(set) var gesture: (cid: UInt16, gesture: Config.Binding.Gesture)?
    private(set) var native: Set<UInt16> = []
    private(set) var middle: Set<UInt16> = []
    /// Drag Lock has the left button down.
    private(set) var dragging = false
    private let post: (UInt16, Bool) -> Bool
    private let postMiddle: (Bool) -> Bool
    private let postLeft: (Bool) -> Bool

    init(post: @escaping (UInt16, Bool) -> Bool = { NativeButton.post($0, down: $1) },
         postMiddle: @escaping (Bool) -> Bool = { NativeButton.postMiddle(down: $0) },
         postLeft: @escaping (Bool) -> Bool = { NativeButton.postLeft(down: $0) }) {
        self.post = post
        self.postMiddle = postMiddle
        self.postLeft = postLeft
    }

    /// Drag Lock: presses the left button, or lets go of the one it pressed.
    mutating func toggleDragLock() {
        if dragging {
            _ = postLeft(false)
            dragging = false
        } else {
            dragging = postLeft(true)
        }
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

    /// Presses the middle button for `cid`, held until `cid` is let go.
    mutating func pressMiddle(_ cid: UInt16) {
        if postMiddle(true) { middle.insert(cid) }
    }

    /// Lets go of `cid`: a native click or a held middle click is released; the gesture it held
    /// is returned.
    mutating func release(_ cid: UInt16) -> Config.Binding.Gesture? {
        if native.remove(cid) != nil {
            _ = post(cid, false)
            return nil
        }
        if middle.remove(cid) != nil {
            _ = postMiddle(false)
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
        if !middle.isEmpty {
            _ = postMiddle(false)
            middle = []
        }
        if dragging {
            _ = postLeft(false)
            dragging = false
        }
        pressed = []
        gesture = nil
    }
}
