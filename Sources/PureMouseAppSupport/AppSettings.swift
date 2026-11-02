import Foundation

/// A thumb wheel suggestion for a well-known app, after Logi Options+'s own defaults.
struct AppSuggestion: Equatable {
    /// The app's name, shown when it is not installed.
    let name: String
    /// A `thumbWheel.action` name.
    let thumbWheel: String

    /// Bundle IDs (lowercased, as they match) to suggestions.
    static let table: [String: AppSuggestion] = [
        "com.google.chrome": AppSuggestion(name: "Google Chrome", thumbWheel: "tabs"),
        "com.apple.safari": AppSuggestion(name: "Safari", thumbWheel: "tabs"),
        "com.microsoft.edgemac": AppSuggestion(name: "Microsoft Edge", thumbWheel: "tabs"),
        "org.mozilla.firefox": AppSuggestion(name: "Firefox", thumbWheel: "tabs"),
        "company.thebrowser.browser": AppSuggestion(name: "Arc", thumbWheel: "tabs"),
        "us.zoom.xos": AppSuggestion(name: "Zoom", thumbWheel: "volume"),
        "com.microsoft.teams2": AppSuggestion(name: "Microsoft Teams", thumbWheel: "volume"),
        "com.microsoft.teams": AppSuggestion(name: "Microsoft Teams", thumbWheel: "volume"),
        "com.microsoft.word": AppSuggestion(name: "Microsoft Word", thumbWheel: "zoom"),
        "com.microsoft.powerpoint": AppSuggestion(name: "Microsoft PowerPoint", thumbWheel: "zoom"),
        "com.apple.preview": AppSuggestion(name: "Preview", thumbWheel: "zoom"),
        "com.microsoft.excel": AppSuggestion(name: "Microsoft Excel", thumbWheel: "scroll"),
    ]

    /// The suggestion for a bundle ID, matched regardless of case as the daemon matches apps.
    static func forApp(_ bundleID: String) -> AppSuggestion? { table[bundleID.lowercased()] }

    var choice: ThumbWheelChoice { thumbWheel == "scroll" ? .scroll : .preset(thumbWheel) }
}

/// `apps.<bundle id>`: settings that differ in one app (docs/configuration.md, "Per-app settings").
/// The Apps pane owns, per app, the button bindings it shows, the thumb wheel's `action`, `left`,
/// `right` and `step`, and `smoothScroll.speed` and `smoothingMs`; every other key stays.
extension ConfigTree {
    /// The bundle IDs `apps` names, as written, sorted without regard to case.
    var appIDs: [String] {
        guard let apps = self[["apps"]] as? [String: Any] else { return [] }
        return apps.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The key that holds an app's entry: an existing one that matches regardless of case (as the
    /// daemon matches them), else the bundle ID as given.
    func appKey(_ bundleID: String) -> String {
        appIDs.first { $0.caseInsensitiveCompare(bundleID) == .orderedSame } ?? bundleID
    }

    func hasApp(_ bundleID: String) -> Bool { contains(["apps", appKey(bundleID)]) }

    /// Where an app's sections live, for `bind(_:to:in:)` and the thumb wheel helpers.
    static func appScope(_ key: String) -> [String] { ["apps", key] }

    /// Removes an app's entry, every key in it included.
    mutating func removeApp(_ bundleID: String) {
        set(nil, at: Self.appScope(appKey(bundleID)))
    }

    // MARK: Buttons

    /// Binds a button in one app. `.standard` removes the app's key, so the global binding applies.
    /// `.gesture` keeps the app's gesture, or starts one whose click does what the button did
    /// there, so its object is never empty.
    mutating func bindInApp(_ app: String, button: String, to binding: ButtonAction) {
        let scope = Self.appScope(app)
        guard binding == .gesture else {
            bind(button, to: binding, in: scope)
            return
        }
        if case .gesture = self.binding(button, in: scope) { return }
        let path = scope + ["buttons", buttonKey(button, in: scope)]
        let click: Any
        if let own = self[path], own is String || own is [String: Any] {
            click = own
        } else {
            let global = ["buttons", buttonKey(button)]
            switch self.binding(button) {
            case .standard: click = "none"
            case .gesture: click = self[global + ["click"]] ?? "none"
            default: click = self[global] ?? "none"
            }
        }
        set(["click": click], at: path)
    }

    /// Binds one direction of an app's gesture. `.standard` removes the key, so the global
    /// gesture's direction applies; the last one removes the app's binding (an empty gesture is
    /// not one). Anything else, "Do Nothing" included, is written as given.
    mutating func bindInApp(_ app: String, button: String, direction: String, to binding: ButtonAction) {
        let scope = Self.appScope(app)
        let key = buttonKey(button, in: scope)
        let path = scope + ["buttons", key]
        switch binding {
        case .standard:
            let others = (self[path] as? [String: Any])?.keys.filter { $0 != direction } ?? []
            set(nil, at: others.isEmpty ? path : path + [direction])
        case .gesture:
            break
        default:
            set(binding.json, at: path + [direction])
        }
    }

    // MARK: Scrolling

    static let scrollOverrideKeys = ["speed", "smoothingMs"]

    /// The app sets its own scrolling speed or glide.
    func overridesScrolling(_ app: String) -> Bool {
        Self.scrollOverrideKeys.contains { contains(Self.appScope(app) + ["smoothScroll", $0]) }
    }

    /// Turns the app's own speed and glide on, starting from the global values, or off, removing
    /// them (and `smoothScroll` and the app's entry when nothing else is left in them).
    mutating func setOverridesScrolling(_ app: String, _ on: Bool) {
        let path = Self.appScope(app) + ["smoothScroll"]
        if on {
            guard !overridesScrolling(app) else { return }
            set(double(["smoothScroll", "speed"]) ?? 1, at: path + ["speed"])
            set(double(["smoothScroll", "smoothingMs"]) ?? 125, at: path + ["smoothingMs"])
        } else {
            for key in Self.scrollOverrideKeys { set(nil, at: path + [key]) }
        }
    }

    /// Whether the app's scrolling glides: its own `smoothScroll.enabled`, else the global one's.
    /// A `smoothScroll` in the app turns it on where there is none globally (Kit's `decodeApps`).
    func scrollsSmoothly(_ app: String) -> Bool {
        let own = Self.appScope(app) + ["smoothScroll"]
        if let enabled = bool(own + ["enabled"]) { return enabled }
        if contains(["smoothScroll"]) { return smoothScrollEnabled }
        return contains(own)
    }

    // MARK: Summary

    /// What an app changes, in a few words for its row: "Thumb wheel: Switch Tabs, 2 buttons".
    func appSummary(_ app: String) -> String {
        let scope = Self.appScope(app)
        var parts: [String] = []
        let choice = thumbWheelChoice(at: scope + ["thumbWheel"])
        let direction = bool(scope + ["thumbWheel", "reversed"]).map { $0 ? "reversed" : "normal direction" }
        switch (choice != .inherit, direction) {
        case (true, let direction?): parts.append("Thumb wheel: \(choice.label), \(direction)")
        case (true, nil): parts.append("Thumb wheel: \(choice.label)")
        case (false, let direction?): parts.append("Thumb wheel: \(direction.prefix(1).uppercased() + direction.dropFirst())")
        case (false, nil): break
        }
        let buttons = (self[scope + ["buttons"]] as? [String: Any])?.count ?? 0
        if buttons > 0 { parts.append(buttons == 1 ? "1 button" : "\(buttons) buttons") }
        if overridesScrolling(app) { parts.append("Scrolling speed") }
        return parts.isEmpty ? "Same as Everywhere" : parts.joined(separator: ", ")
    }
}
