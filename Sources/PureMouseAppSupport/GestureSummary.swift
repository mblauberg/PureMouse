import Foundation

/// The caption under a Hold and Move button's collapsed row: what a click does and how many
/// directions do something ("Click: Mission Control, 4 directions set.").
public enum GestureSummary {
    public static func text(click: ButtonAction, directionsSet: Int) -> String {
        let click = click == .standard || click == .mouseDefault ? ActionCatalog.label(for: "none") : click.label
        let directions = switch directionsSet {
        case 0: "no directions set"
        case 1: "1 direction set"
        default: "\(directionsSet) directions set"
        }
        return "Click: \(click), \(directions)."
    }
}

extension ConfigTree {
    /// The summary for a gesture button at `scope` (the top level, an app or a device). A device's
    /// is what applies on that mouse: its directions over the top level's.
    public func gestureSummary(_ button: String, in scope: ConfigScope = .global) -> String {
        func action(_ direction: String) -> ButtonAction {
            guard scope.deviceKey != nil else { return gestureBinding(button, direction, in: scope) }
            return ButtonAction(json: resolved(["buttons", button, direction], in: scope))
        }
        let moves = Gesture.directions.filter { $0 != "click" }.filter {
            action($0) != .standard && action($0) != .named("none")
        }
        return GestureSummary.text(click: action("click"), directionsSet: moves.count)
    }

    /// Some button is Hold and Move: globally, in an app or on one mouse. Gesture distance and
    /// repeat matter only then.
    public var usesGestures: Bool {
        let scopes = [[]] + ["apps", "devices"].flatMap { section in
            ((self[[section]] as? [String: Any])?.keys.sorted() ?? []).map { [section, $0] }
        }
        return scopes.contains { prefix in
            let buttons = self[prefix + ["buttons"]] as? [String: Any] ?? [:]
            return buttons.values.contains { ButtonAction(json: $0) == .gesture }
        }
    }
}
