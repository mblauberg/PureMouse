import Foundation

extension ConfigTree {
    /// Some button is Hold and Move (a table with a direction that does something): globally, in an
    /// app or on one mouse. Hold and Move's distance and repeat matter only then.
    public var usesGestures: Bool {
        let scopes = [[]] + ["apps", "devices"].flatMap { section in
            ((self[[section]] as? [String: Any])?.keys.sorted() ?? []).map { [section, $0] }
        }
        return scopes.contains { prefix in
            let buttons = self[prefix + ["buttons"]] as? [String: Any] ?? [:]
            return buttons.values.contains { binding in
                Self.table(binding).map { table in Gesture.directions.contains { Self.isSet(table[$0]) } } ?? false
            }
        }
    }
}
