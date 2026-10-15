import CoreGraphics
import PureMouseKit

extension Keystroke {
    func post() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = eventFlags
            event.post(tap: .cghidEventTap)
        }
    }
}
