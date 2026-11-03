import PureMouseKit

/// What a press of one control does, compiled from its binding when the session starts (ADR 24),
/// so a press only reads it. A bare action, a table that sets only a click, and a while-held
/// click are `immediate`: the click fires on press and nothing is armed, as before triggers.
struct PressPlan: Equatable {
    /// The click; nil for no binding, the mouse's own behaviour (`Session.performNative`).
    var click: Action?
    /// Watched for only when set: a lone click then waits the double-click interval.
    var doubleClick: Action?
    var hold: Hold = .none

    enum Hold: Equatable {
        case none
        /// Fires once at `Config.holdMs`; a while-held one lasts until the release.
        case action(Action)
        /// Hold and Move: the directions, recognised from raw pointer motion.
        case move(Config.Binding.Gesture)
    }

    init(_ binding: Config.Binding?) {
        switch binding {
        case nil:
            click = nil
        case .action(let action):
            click = action
        case .gesture(let table):
            click = table.click
            // A while-held click owns the button: nothing else can be told apart from it.
            guard !table.click.isWhileHeld else { return }
            doubleClick = table.doubleClick == .none ? nil : table.doubleClick
            hold = table.moves ? .move(table) : table.hold == .none ? .none : .action(table.hold)
        }
    }

    /// The click fires at the press: there is no other trigger to tell it from.
    var immediate: Bool { doubleClick == nil && hold == .none }

    var moves: Bool { if case .move = hold { true } else { false } }
}

/// A press under way: from the press until its release, and after a click while it waits for a
/// second (`waiting`). Its `deadline` is the hold, or the double-click wait.
struct Press {
    let plan: PressPlan
    var stage: Stage
    var deadline: Deadline?

    enum Stage: Equatable {
        /// Down, nothing fired yet: a release is a click.
        case down
        /// The hold or a direction fired, or the second press of a double-click: the release does
        /// nothing more.
        case done
        /// Released after a click, waiting for a second press.
        case waiting
    }
}
