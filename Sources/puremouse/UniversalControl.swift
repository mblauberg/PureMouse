import Foundation
import notify

/// Universal Control's input state, as published in an undocumented Darwin notification's state
/// (found in Logi Options+'s agent; bits as observed on macOS 27). Crossing to another Mac sets
/// `pointerAway` (0x2); clicking there brings the keyboard too (0x1, so 0x3). Coming back clears
/// the pointer bit first (0x1), then the keyboard's (0x0).
struct UniversalControlState: Equatable {
    var raw: UInt64

    /// The pointer, and with it the mouse's input, is on another Mac.
    var pointerAway: Bool { raw & 0x2 != 0 }
    /// The keyboard is on another Mac.
    var keyboardAway: Bool { raw & 0x1 != 0 }

    static let home = UniversalControlState(raw: 0)
}

/// Calls `onChange` on the main actor when the pointer moves to another Mac or back. Event-driven:
/// one Darwin notification registration, nothing polled.
@MainActor
final class UniversalControlWatcher {
    /// Per user, e.g. `user.uid.501.com.apple.universalcontrol.inputstate`.
    static var notificationName: String { "user.uid.\(getuid()).com.apple.universalcontrol.inputstate" }

    private(set) var state = UniversalControlState.home
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private let onChange: (UniversalControlState) -> Void

    init(onChange: @escaping (UniversalControlState) -> Void) {
        self.onChange = onChange
    }

    /// Registers and reads the current state, calling `onChange` if the pointer is already away.
    func start() {
        guard token == NOTIFY_TOKEN_INVALID else { return }
        let status = notify_register_dispatch(Self.notificationName, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        guard status == NOTIFY_STATUS_OK else {
            Log.error("watching Universal Control failed: \(status)")
            token = NOTIFY_TOKEN_INVALID
            return
        }
        read()
    }

    func stop() {
        guard token != NOTIFY_TOKEN_INVALID else { return }
        notify_cancel(token)
        token = NOTIFY_TOKEN_INVALID
    }

    private func read() {
        guard token != NOTIFY_TOKEN_INVALID else { return }
        var raw: UInt64 = 0
        guard notify_get_state(token, &raw) == NOTIFY_STATUS_OK else { return }
        let new = UniversalControlState(raw: raw)
        let pointerMoved = new.pointerAway != state.pointerAway
        state = new
        if pointerMoved { onChange(new) }
    }
}

/// What a session wants from the mouse while the pointer is here or on another Mac.
enum Handoff {
    /// Whether the mice are handed back to macOS: the pointer is on another Mac and the config
    /// allows it (`universalControl.handOff`).
    static func handingOff(pointerAway: Bool, enabled: Bool) -> Bool {
        pointerAway && enabled
    }

    /// Controls to divert: bound ones and those diverted for select-by-pressing, none while away.
    static func wantedControls(bound: Set<UInt16>, capturing: Set<UInt16>?, away: Bool) -> Set<UInt16> {
        away ? [] : bound.union(capturing ?? [])
    }

    /// Whether the wheels report to PureMouse: scrolling runs here (smooth scrolling or
    /// thumb-wheel actions), permission to post the scroll events, and the pointer here.
    static func wheelsDiverted(scrolling: Bool, accessibility: Bool, away: Bool) -> Bool {
        scrolling && accessibility && !away
    }
}
