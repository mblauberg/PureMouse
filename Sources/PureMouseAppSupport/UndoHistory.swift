import Foundation

/// Settings' undo and redo: each config change registered on the window's `UndoManager` as the
/// inverse of what it changed, with a name for the Edit menu ("Undo Pointer Speed").
///
/// Only the Settings helper has one (`AppModel.undoManager`); the menu bar app's store has none and
/// pays nothing. The inverse is `after.changes(to: before)` over the file's own keys (not the
/// tree laid over the defaults), replayed with `ConfigTree.apply` by `ConfigStore.replay`, so
/// undoing writes the file exactly as it was, and registers its own inverse as the redo.
///
/// Foundation only: no AppKit, no SwiftUI.
@MainActor
public final class UndoHistory {
    /// A step the debounce is still collecting into: the config before its first change and after
    /// its latest.
    private final class Step {
        let before: ConfigTree
        var after: ConfigTree
        /// The keys its first change set: a later change joins only if it touches no others.
        let paths: Set<[String]>
        init(before: ConfigTree, after: ConfigTree, paths: Set<[String]>) {
            self.before = before
            self.after = after
            self.paths = paths
        }
    }

    let manager: UndoManager
    /// Replays an inverse onto the file.
    private let restore: @MainActor (_ changes: [ConfigTree.Change]) -> Void
    private var open: Step?

    init(manager: UndoManager, restore: @escaping @MainActor (_ changes: [ConfigTree.Change]) -> Void) {
        self.manager = manager
        self.restore = restore
        // Each change is its own group, closed here, not at the end of the event: a step is never
        // left open for a later one to join except through the debounce.
        manager.groupsByEvent = false
    }

    /// Registers the change from `before` to `after` as one undoable step. With `debounce`, a
    /// change that arrives before the write has flushed joins the step already open (one slider
    /// drag is one step); any other change closes it first, including one to other keys than the
    /// step's first change set (two controls inside the window are two steps). An undo or redo
    /// never joins one.
    func record(from before: ConfigTree, to after: ConfigTree, debounce: Bool) {
        let changes = before.changes(to: after)
        guard !changes.isEmpty else { return }
        let paths = Set(changes.map(\.path))
        let replaying = manager.isUndoing || manager.isRedoing
        if !debounce || replaying || open.map({ !paths.isSubset(of: $0.paths) }) == true { open = nil }
        if let step = open {
            // The step keeps the name its first change gave it: the group it was registered in is
            // closed, and naming one that is closed is an error.
            step.after = after
            return
        }
        let step = Step(before: before, after: after, paths: paths)
        if debounce { open = step }
        // An undo or redo is already inside its own group, which the step it registers joins.
        if !replaying { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated { history.restore(step.after.changes(to: step.before)) }
        }
        manager.setActionName(Self.name(of: changes, from: before, to: after))
        if !replaying { manager.endUndoGrouping() }
    }

    /// Ends the step the debounce is collecting into: the write it waited for has happened.
    func flushed() { open = nil }

    /// Forgets every step, undo and redo: the file changed under them, or a write failed.
    func clear() {
        open = nil
        manager.removeAllActions(withTarget: self)
    }

    // MARK: Names

    /// The Edit menu's name for a step, from the keys it changed (`Undo <name>`). The path is read
    /// after `devices.<key>.` or `apps.<id>.`; one name for all of them is that name, anything else
    /// is "Changes".
    static func name(of changes: [ConfigTree.Change], from before: ConfigTree, to after: ConfigTree) -> String {
        var names: Set<String> = []
        var smoothScrollKeys: Set<String> = []
        var apps: Set<String> = []
        for change in changes {
            var path = change.path[...]
            if path.first == "devices", path.count >= 2 {
                path = path.dropFirst(2)
                // The name a first write gives the entry says nothing of its own.
                if path == ["name"] { continue }
            } else if path.first == "apps", path.count >= 2 {
                apps.insert(path[path.startIndex + 1])
                path = path.dropFirst(2)
                if path.isEmpty {
                    names.insert("App Settings")
                    continue
                }
            }
            if path.first == "smoothScroll", path.count == 2,
               ["acceleration", "smoothingMs"].contains(path[path.startIndex + 1]) {
                smoothScrollKeys.insert(path[path.startIndex + 1])
                continue
            }
            names.insert(name(ofKey: Array(path)) ?? "Changes")
        }
        switch smoothScrollKeys {
        case ["acceleration", "smoothingMs"]: names.insert("Feel")
        case ["acceleration"]: names.insert("Acceleration")
        case ["smoothingMs"]: names.insert("Glide")
        default: break
        }
        // A whole app entry added or removed, however many keys it held.
        if apps.count == 1, let id = apps.first, names.count > 1,
           (before[["apps", id]] == nil) != (after[["apps", id]] == nil) {
            return "App Settings"
        }
        return names.count == 1 ? names.first! : "Changes"
    }

    private static func name(ofKey path: [String]) -> String? {
        switch path.first {
        case "dpi": return "Pointer Speed"
        case "dpiPresets": return "Presets"
        case "smoothScroll":
            switch path.dropFirst().first {
            case "speed": return "Scrolling Speed"
            case "enabled": return "Smooth Scrolling"
            // The thumb wheel's Speed, in its Advanced sheet.
            case "horizontalSpeed": return "Thumb Wheel"
            default: return nil
            }
        case "scrollWheel":
            switch path.dropFirst().first {
            case "inverted": return "Reverse Direction"
            case "mode": return "Wheel Mode"
            case "smartShiftThreshold": return "SmartShift"
            default: return nil
            }
        case "thumbWheel": return "Thumb Wheel"
        case "buttons": return "Button Action"
        case "gesture": return "Hold and Move"
        case "notifications": return path.dropFirst().first == "lowBattery" ? "Low Battery Notification" : nil
        case "universalControl": return path.dropFirst().first == "handOff" ? "Universal Control" : nil
        default: return nil
        }
    }
}
