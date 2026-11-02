import Foundation

/// The caption under a Hold and Move button's collapsed row: what a click does and how many
/// directions do something ("Click: Mission Control, 4 directions set.").
public enum GestureSummary {
    public static func text(click: ButtonAction, directionsSet: Int) -> String {
        let click = click == .standard ? ActionCatalog.label(for: "none") : click.label
        let directions = switch directionsSet {
        case 0: "no directions set"
        case 1: "1 direction set"
        default: "\(directionsSet) directions set"
        }
        return "Click: \(click), \(directions)."
    }
}

extension ConfigTree {
    /// The summary for a gesture button at `scope` (the top level, or an app).
    public func gestureSummary(_ button: String, in scope: [String] = []) -> String {
        let moves = Gesture.directions.filter { $0 != "click" }.filter {
            let action = gestureBinding(button, $0, in: scope)
            return action != .standard && action != .named("none")
        }
        return GestureSummary.text(click: gestureBinding(button, "click", in: scope), directionsSet: moves.count)
    }

    /// Some button is Hold and Move: globally, in an app or on one mouse. Gesture distance and
    /// repeat matter only then.
    public var usesGestures: Bool {
        let scopes = [[]] + ["apps", "devices"].flatMap { section in
            ((self[[section]] as? [String: Any])?.keys.sorted() ?? []).map { [section, $0] }
        }
        return scopes.contains { scope in
            let buttons = self[scope + ["buttons"]] as? [String: Any] ?? [:]
            return buttons.keys.contains { binding($0, in: scope) == .gesture }
        }
    }
}
