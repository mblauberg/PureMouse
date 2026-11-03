import Foundation

/// A thumb wheel suggestion for a well-known app, after Logi Options+'s own defaults.
public struct AppSuggestion: Equatable, Sendable {
    /// The app's name, shown when it is not installed.
    public let name: String
    /// A `thumbWheel.action` name.
    public let thumbWheel: String

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
    public static func forApp(_ bundleID: String) -> AppSuggestion? { table[bundleID.lowercased()] }

    public var choice: ThumbWheelChoice { thumbWheel == "scroll" ? .scroll : .preset(thumbWheel) }
}

/// `apps.<bundle id>`: settings that differ in one app (docs/configuration.md, "Per-app settings").
/// The Apps pane owns, per app, the button bindings it shows, the thumb wheel's `action`, `left`,
/// `right` and `step`, and `smoothScroll.speed` and `smoothingMs`; every other key stays.
extension ConfigTree {
    /// The bundle IDs `apps` names, as written, sorted without regard to case.
    public var appIDs: [String] {
        guard let apps = self[["apps"]] as? [String: Any] else { return [] }
        return apps.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The key that holds an app's entry: an existing one that matches regardless of case (as the
    /// daemon matches them), else the bundle ID as given.
    public func appKey(_ bundleID: String) -> String {
        appIDs.first { $0.caseInsensitiveCompare(bundleID) == .orderedSame } ?? bundleID
    }

    public func hasApp(_ bundleID: String) -> Bool { contains(["apps", appKey(bundleID)]) }

    /// Where an app's sections live, for `bind(_:to:in:)` and the thumb wheel helpers.
    public static func appScope(_ key: String) -> ConfigScope { .app(key) }

    /// Removes an app's entry, every key in it included.
    public mutating func removeApp(_ bundleID: String) {
        set(nil, at: [], in: Self.appScope(appKey(bundleID)))
    }

    // MARK: Buttons

    /// Binds a button in one app. `.standard` removes the app's key, so the global binding applies;
    /// `.mouseDefault` writes `"default"`, so the button is native in the app whatever is global.
    /// `.gesture` keeps the app's gesture, or starts one whose click does what the button did
    /// there, so its object is never empty.
    public mutating func bindInApp(_ app: String, button: String, to binding: ButtonAction) {
        let scope = Self.appScope(app)
        guard binding == .gesture else {
            bind(button, to: binding, in: scope)
            return
        }
        if case .gesture = self.binding(button, in: scope) { return }
        // Mouse Default hides the global gesture; choosing Hold and Move gives it back whole.
        if self.binding(button, in: scope) == .mouseDefault, self.binding(button) == .gesture {
            bind(button, to: .standard, in: scope)
            return
        }
        let path = scope.prefix + ["buttons", buttonKey(button, in: scope)]
        let click: Any
        if self.binding(button, in: scope) == .mouseDefault {
            click = "none"  // native in this app: the gesture's click then does nothing
        } else if let own = self[path], own is String || own is [String: Any] {
            click = own
        } else {
            let global = ["buttons", buttonKey(button)]
            switch self.binding(button) {
            case .standard, .mouseDefault: click = "none"
            case .gesture: click = self[global + ["click"]] ?? "none"
            default: click = self[global] ?? "none"
            }
        }
        set(["click": click], at: path)
    }

    /// Binds one direction of an app's gesture. `.standard` removes the key, so the global
    /// gesture's direction applies; the last one removes the app's binding (an empty gesture is
    /// not one). Anything else, "Do Nothing" included, is written as given.
    public mutating func bindInApp(_ app: String, button: String, direction: String, to binding: ButtonAction) {
        // The same rules as a mouse's: only `.standard` removes the key, and the last direction takes
        // the whole binding with it.
        bind(button, direction: direction, to: binding, in: Self.appScope(app))
    }

    // MARK: Scrolling

    static let scrollOverrideKeys = ["speed", "smoothingMs"]

    /// The app sets its own scrolling speed or glide ("Custom scrolling").
    public func overridesScrolling(_ app: String) -> Bool {
        Self.scrollOverrideKeys.contains { contains(Self.appScope(app).prefix + ["smoothScroll", $0]) }
    }

    /// Turns the app's own speed and glide on, starting from the global values, or off, removing
    /// them (and `smoothScroll` and the app's entry when nothing else is left in them).
    public mutating func setOverridesScrolling(_ app: String, _ on: Bool) {
        let path = Self.appScope(app).prefix + ["smoothScroll"]
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
    public func scrollsSmoothly(_ app: String) -> Bool {
        let own = Self.appScope(app).prefix + ["smoothScroll"]
        if let enabled = bool(own + ["enabled"]) { return enabled }
        if contains(["smoothScroll"]) { return smoothScrollEnabled }
        return contains(own)
    }

    /// The caption under "Custom scrolling": what the app's scrolling does. Off, it follows
    /// Scrolling; on, it says whether the glide applies, since an app's `smoothScroll` turns smooth
    /// scrolling on where there is none globally (`scrollsSmoothly`).
    public func customScrollingCaption(_ app: String) -> String {
        if !overridesScrolling(app) { return "Uses Scrolling's speed and glide." }
        if !scrollsSmoothly(app) { return "Smooth scrolling is off, so this app scrolls at this speed without the glide." }
        if !smoothScrollEnabled { return "Smooth scrolling is on in this app only." }
        return "Smooth scrolling is on, as set in Scrolling."
    }

    // MARK: Sheet

    /// A button as an app's sheet shows it. Reading it writes nothing.
    public func appButton(_ app: String, button: String) -> AppButton {
        scopedButton(button, in: Self.appScope(app))
    }

    /// A button as a row shows it in an app or on a mouse: the scope's own binding over the top
    /// level's, which applies while the scope leaves the button alone (`own` is `.standard`).
    public func scopedButton(_ button: String, in scope: ConfigScope) -> AppButton {
        let own = binding(button, in: scope)
        let everywhere = binding(button)
        // A plain action of the app's own replaces a global gesture, so it has no directions.
        guard own == .gesture || (own == .standard && everywhere == .gesture) else {
            return AppButton(own: own, everywhere: everywhere, directions: [])
        }
        let directions = Gesture.directions.map { direction in
            AppButton.Direction(name: direction, own: gestureBinding(button, direction, in: scope),
                                everywhere: everywhere == .gesture ? gestureBinding(button, direction) : nil)
        }
        return AppButton(own: own, everywhere: everywhere, directions: directions)
    }

    // MARK: Summary

    /// What an app changes, in a few words for its row, joined with commas: "Thumb wheel: Switch
    /// Tabs, 2 buttons changed, Custom scrolling".
    public func appSummary(_ app: String) -> String {
        let scope = Self.appScope(app)
        var parts: [String] = []
        let choice = thumbWheelChoice(at: scope.prefix + ["thumbWheel"])
        let direction = bool(scope.prefix + ["thumbWheel", "reversed"]).map { $0 ? "directions swapped" : "directions not swapped" }
        switch (choice != .inherit, direction) {
        case (true, let direction?): parts.append("Thumb wheel: \(choice.label), \(direction)")
        case (true, nil): parts.append("Thumb wheel: \(choice.label)")
        case (false, let direction?): parts.append("Thumb wheel: \(direction.prefix(1).uppercased() + direction.dropFirst())")
        case (false, nil): break
        }
        let buttons = (self[scope.prefix + ["buttons"]] as? [String: Any])?.count ?? 0
        if buttons > 0 { parts.append(buttons == 1 ? "1 button changed" : "\(buttons) buttons changed") }
        if overridesScrolling(app) { parts.append("Custom scrolling") }
        return parts.isEmpty ? AppList.noCustomSettings : parts.joined(separator: ", ")
    }
}

/// A button in an app's sheet: the app's own binding and the one everywhere, which applies while
/// the app leaves the button alone (`own` is `.standard`).
public struct AppButton: Equatable, Sendable {
    /// One gesture direction: the app's own (`.standard` when it leaves it out) and, when the
    /// button is a gesture everywhere, the global direction, which applies while the app's is unset.
    public struct Direction: Equatable, Sendable {
        public let name: String
        public let own: ButtonAction
        public let everywhere: ButtonAction?

        /// The scope sets this direction itself, whether or not a wider gesture has one.
        public var isOwn: Bool { own != .standard }

        /// What applies while the scope leaves the direction out: the wider gesture's, else nothing.
        public var inherited: ButtonAction {
            guard let everywhere, everywhere != .standard else { return .named("none") }
            return everywhere
        }
    }

    public let own: ButtonAction
    public let everywhere: ButtonAction
    /// The gesture's directions, when the button is a gesture in this app: its own, or the global
    /// one it inherits (Hold and Move everywhere, nothing set here). Empty otherwise.
    public let directions: [Direction]

    /// The app leaves the button to a gesture set everywhere: its directions show, collapsed and
    /// shown as for any inherited row, and editing one writes only that direction under the app
    /// (`ConfigTree.bindInApp(_:button:direction:to:)`).
    public var inheritsGesture: Bool { own == .standard && everywhere == .gesture }
}

/// The Apps list: the apps the config names, plus those added in this session, which are saved
/// only once one has a setting; and the app whose sheet is open.
public struct AppList: Equatable, Sendable {
    /// The row summary of an app with nothing of its own (added, not yet saved).
    public static let noCustomSettings = "No custom settings"

    /// Apps added here that have no setting yet: nothing is written until one is set.
    public private(set) var added: [String] = []
    /// The app whose sheet is open, by its key under `apps`.
    public var open: String?

    public init() {}

    /// The configured apps and those added here, unsorted.
    public func ids(in config: ConfigTree) -> [String] {
        config.appIDs + added.filter { !config.hasApp($0) }
    }

    /// An app added here stays listed until Settings closes, but is saved only with a setting.
    public func summary(_ id: String, in config: ConfigTree) -> String {
        config.hasApp(id) ? config.appSummary(id) : Self.noCustomSettings
    }

    /// Adds an app (unless listed) and opens its sheet.
    public mutating func add(_ bundleID: String, in config: ConfigTree) {
        let key = config.appKey(bundleID)
        if !config.hasApp(key), !added.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            added.append(key)
        }
        open = key
    }

    /// Removes an app's entry and its row, and closes its sheet if open.
    public mutating func remove(_ id: String, from config: inout ConfigTree) {
        config.removeApp(id)
        added.removeAll { $0.caseInsensitiveCompare(id) == .orderedSame }
        if open?.caseInsensitiveCompare(id) == .orderedSame { open = nil }
    }

    /// The alert for an app PureMouse can't add: one without a bundle identifier. `url` is the app
    /// chosen; it is named without ".app".
    public static func cannotAdd(_ url: URL) -> (title: String, message: String) {
        ("\(url.deletingPathExtension().lastPathComponent) can't be added.",
         "PureMouse can't identify it. Choose a different app.")
    }
}
