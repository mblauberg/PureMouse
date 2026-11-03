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

    /// The caption under Use PureMouse in this app, and the note once it is off.
    public static let useInAppCaption = "Applies your buttons and scrolling here. Turn off for games and remote desktops."
    public static let useInAppOffNote = "Pointer speed and wheel mode stay, because they belong to the mouse."

    /// Whether PureMouse applies in this app (a bundle ID matched regardless of case); absent means on.
    public func isAppEnabled(_ app: String) -> Bool {
        bool(Self.appScope(appKey(app)).prefix + ["enabled"]) ?? true
    }

    /// Turns PureMouse on or off in an app. Absent means on: on removes the key (or writes
    /// nothing); off writes `false`.
    public mutating func setAppEnabled(_ app: String, _ on: Bool) {
        let path = Self.appScope(appKey(app)).prefix + ["enabled"]
        set(on ? nil : false, at: path)
    }

    // MARK: Buttons

    /// Binds a button in one app. `.standard` removes the app's key, so the wider binding applies;
    /// `.mouseDefault` writes `"default"`, so the button is native in the app whatever is bound wider.
    /// `.gesture` keeps the app's gesture, or starts one whose click does what the button did there:
    /// what applies to the first of the `inheriting` scopes (`AppModel.appInheritedScopes`), which is
    /// the value the app's page shows, so its object is never empty.
    public mutating func bindInApp(_ app: String, button: String, to binding: ButtonAction,
                                   inheriting: [ConfigScope] = [.global]) {
        let scope = Self.appScope(app)
        guard binding == .gesture else {
            bind(button, to: binding, in: scope)
            return
        }
        if case .gesture = self.binding(button, in: scope) { return }
        // What applies where the app leaves the button alone.
        let wider = inheriting.first ?? .global
        let inherited: Any? = wider.deviceKey != nil ? resolved(["buttons", button], in: wider) : self[["buttons", buttonKey(button)]]
        // Mouse Default hides the wider gesture; choosing Hold and Move gives it back whole.
        if self.binding(button, in: scope) == .mouseDefault, ButtonAction(json: inherited) == .gesture {
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
            switch ButtonAction(json: inherited) {
            case .standard, .mouseDefault: click = "none"
            case .gesture: click = (inherited as? [String: Any])?["click"] ?? "none"
            default: click = inherited ?? "none"
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

    /// Turns the app's own speed and glide on, starting from the values that apply to the first of
    /// the `inheriting` scopes (`AppModel.appInheritedScopes`), or off, removing them (and `smoothScroll`
    /// and the app's entry when nothing else is left in them).
    public mutating func setOverridesScrolling(_ app: String, _ on: Bool, inheriting: [ConfigScope] = [.global]) {
        let path = Self.appScope(app).prefix + ["smoothScroll"]
        if on {
            guard !overridesScrolling(app) else { return }
            let wider = inheriting.first ?? .global
            set(number(["smoothScroll", "speed"], in: wider, default: 1), at: path + ["speed"])
            set(number(["smoothScroll", "smoothingMs"], in: wider, default: 125), at: path + ["smoothingMs"])
        } else {
            for key in Self.scrollOverrideKeys { set(nil, at: path + [key]) }
        }
    }

    /// Whether the app's scrolling glides on some mouse. Kit layers the app's `smoothScroll` over each
    /// mouse's, so the app's own `enabled` wins, else the mouse's resolves (on unless it or All Mice
    /// says `enabled: false`: the default set has smooth scrolling on). The app's glide applies, and
    /// Glide is enabled, while it does on any of the mice it may run with.
    public func scrollsSmoothly(_ app: String, inheriting: [ConfigScope] = [.global]) -> Bool {
        let own = bool(Self.appScope(app).prefix + ["smoothScroll", "enabled"])
        return (inheriting.isEmpty ? [.global] : inheriting).contains { own ?? smoothScrollEnabled(in: $0) }
    }

    /// The caption under "Custom scrolling": it describes the on state, whatever the other settings
    /// are (docs/ui-language.md, Captions).
    public static let customScrollingCaption = "Gives this app its own scrolling speed and glide."

    // MARK: Page

    /// A button as an app's page shows it: the app's own binding over what applies to the mice the
    /// app inherits from (`inheriting`, `AppModel.appInheritedScopes`). Reading it writes nothing.
    public func appButton(_ app: String, button: String, inheriting: [ConfigScope] = [.global]) -> AppButton {
        scopedButton(button, in: Self.appScope(app), inheriting: inheriting)
    }

    /// A button as a row shows it in an app or on a mouse: the scope's own binding over what applies
    /// in the wider scopes, which applies while the scope leaves the button alone (`own` is
    /// `.standard`). A mouse's wider scope is the top level; an app's is each mouse it may run
    /// with (`inheriting`), and the value is `Varies by Mouse` when they resolve it differently.
    public func scopedButton(_ button: String, in scope: ConfigScope, inheriting: [ConfigScope] = [.global]) -> AppButton {
        let own = binding(button, in: scope)
        let wider = inheriting.isEmpty ? [ConfigScope.global] : inheriting
        let bindings = wider.map { resolvedBinding(button, in: $0) }
        let everywhere = Applied(bindings)
        // A plain action of the app's own replaces a global gesture, so it has no directions.
        guard own == .gesture || (own == .standard && bindings.contains(.gesture)) else {
            return AppButton(own: own, everywhere: everywhere.first, directions: [], variesByMouse: everywhere.varies)
        }
        let directions = Gesture.directions.map { direction in
            let inherited: [ButtonAction?] = zip(wider, bindings).map { scope, binding in
                binding == .gesture ? resolvedGestureBinding(button, direction, in: scope) : nil
            }
            let none = ButtonAction.named("none")
            let effective = inherited.map { $0 == nil || $0 == .standard ? none : $0! }
            return AppButton.Direction(name: direction, own: gestureBinding(button, direction, in: scope),
                                       everywhere: inherited[0], variesByMouse: Applied(effective).varies)
        }
        return AppButton(own: own, everywhere: everywhere.first, directions: directions, variesByMouse: everywhere.varies)
    }

    // MARK: Summary

    /// The areas of the page an app changes: Buttons when it binds any, Scrolling when it sets the
    /// thumb wheel or its own speed or glide.
    public func appAreas(_ app: String) -> [AppSegment] {
        let scope = Self.appScope(app)
        var areas: [AppSegment] = []
        if !((self[scope.prefix + ["buttons"]] as? [String: Any])?.isEmpty ?? true) { areas.append(.buttons) }
        let thumb = self[scope.prefix + ["thumbWheel"]] as? [String: Any] ?? [:]
        if overridesScrolling(app) || ThumbWheelChoice.keys.contains(where: { thumb[$0] != nil }) || thumb["reversed"] != nil {
            areas.append(.scrolling)
        }
        return areas
    }

    /// What an app changes, for its row in the list: the areas, by name ("Buttons, Scrolling"),
    /// or "Off" when turned off.
    public func appSummary(_ app: String) -> String {
        guard isAppEnabled(app) else { return "Off" }
        let areas = appAreas(app)
        return areas.isEmpty ? AppList.noCustomSettings : areas.map(\.title).joined(separator: ", ")
    }
}

/// An app's page has two segments (there is no Pointer: per-app settings are the buttons, the thumb
/// wheel and scrolling). The thumb wheel sits under Scrolling.
public enum AppSegment: String, CaseIterable, Sendable {
    case buttons, scrolling

    public var title: String {
        switch self {
        case .buttons: "Buttons"
        case .scrolling: "Scrolling"
        }
    }

    /// A group of rows on the page.
    public enum Section: Sendable { case buttons, customScrolling, thumbWheel }

    /// The groups of rows the segment holds, in order.
    public var sections: [Section] {
        switch self {
        case .buttons: [.buttons]
        case .scrolling: [.customScrolling, .thumbWheel]
        }
    }
}

/// A button on an app's page: the app's own binding and the one the mice resolve, which applies
/// while the app leaves the button alone (`own` is `.standard`).
public struct AppButton: Equatable, Sendable {
    /// One gesture direction: the app's own (`.standard` when it leaves it out) and, when the
    /// button is a gesture everywhere, the global direction, which applies while the app's is unset.
    public struct Direction: Equatable, Sendable {
        public let name: String
        public let own: ButtonAction
        public let everywhere: ButtonAction?
        /// The mice resolve this direction differently.
        public var variesByMouse = false

        /// What the row shows while the scope leaves the direction out.
        public var inheritedLabel: String { variesByMouse ? Applied<ButtonAction>.variesLabel : inherited.label }
        public var inheritedSpokenLabel: String { variesByMouse ? Applied<ButtonAction>.variesLabel : inherited.spokenLabel }

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
    /// The mice resolve the button differently, so `everywhere` is only the first one's.
    public var variesByMouse = false

    /// What the row shows while the app leaves the button alone: the value the mice share, else
    /// "Varies by Mouse".
    public var inheritedLabel: String { variesByMouse ? Applied<ButtonAction>.variesLabel : everywhere.label }
    public var inheritedSpokenLabel: String { variesByMouse ? Applied<ButtonAction>.variesLabel : everywhere.spokenLabel }

    /// The caption under a Hold and Move row, as the Mouse page words it (`GestureSummary`): what a
    /// click does and how many directions do something, each the app's own or else the one the mice
    /// give it. nil when the button is no gesture here, or the mice give a direction different things
    /// while the app leaves it alone (the row says "Varies by Mouse", and one mouse's summary would be
    /// wrong for the others).
    public var gestureSummary: String? {
        guard !directions.isEmpty,
              !directions.contains(where: { $0.variesByMouse && !$0.isOwn }) else { return nil }
        func effective(_ direction: Direction) -> ButtonAction { direction.isOwn ? direction.own : direction.inherited }
        let click = directions.first { $0.name == "click" }.map(effective) ?? .standard
        let moves = directions.filter { $0.name != "click" }.map(effective).filter { $0 != .standard && $0 != .named("none") }
        return GestureSummary.text(click: click, directionsSet: moves.count)
    }

    /// The app leaves the button to a gesture set in the mice: its directions show, collapsed and
    /// shown as for any inherited row, and editing one writes only that direction under the app
    /// (`ConfigTree.bindInApp(_:button:direction:to:)`).
    public var inheritsGesture: Bool { own == .standard && !directions.isEmpty }
}

/// The Apps list: the apps the config names, plus those added in this session, which are saved
/// only once one has a setting; and the app whose page is open, on its segment.
public struct AppList: Equatable, Sendable {
    /// The row summary of an app with nothing of its own (added, not yet saved).
    public static let noCustomSettings = "No custom settings"

    /// Apps added here that have no setting yet: nothing is written until one is set.
    public private(set) var added: [String] = []
    /// The app whose page is open, by its key under `apps`.
    public private(set) var open: String?
    /// The page's segment; Buttons each time a page opens. Choosing one writes nothing.
    public private(set) var segment = AppSegment.buttons

    public init() {}

    /// The configured apps and those added here, unsorted.
    public func ids(in config: ConfigTree) -> [String] {
        config.appIDs + added.filter { !config.hasApp($0) }
    }

    /// An app added here stays listed until Settings closes, but is saved only with a setting.
    public func summary(_ id: String, in config: ConfigTree) -> String {
        config.hasApp(id) ? config.appSummary(id) : Self.noCustomSettings
    }

    /// Adds an app (unless listed) and opens its page.
    public mutating func add(_ bundleID: String, in config: ConfigTree) {
        let key = config.appKey(bundleID)
        if !config.hasApp(key), !added.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            added.append(key)
        }
        show(key)
    }

    /// Opens a listed app's page, on Buttons unless it is the page already open.
    public mutating func show(_ key: String) {
        if open != key { segment = .buttons }
        open = key
    }

    /// Shows a segment of the open page.
    public mutating func select(_ segment: AppSegment) { self.segment = segment }

    /// Back to the list (‹ Apps, ⌘[ and Esc).
    public mutating func close() { open = nil }

    /// Removes an app's entry and its row, and closes its page if open.
    public mutating func remove(_ id: String, from config: inout ConfigTree) {
        config.removeApp(id)
        added.removeAll { $0.caseInsensitiveCompare(id) == .orderedSame }
        if open?.caseInsensitiveCompare(id) == .orderedSame { close() }
    }

    /// The alert for an app PureMouse can't add: one without a bundle identifier. `url` is the app
    /// chosen; it is named without ".app".
    public static func cannotAdd(_ url: URL) -> (title: String, message: String) {
        ("\(url.deletingPathExtension().lastPathComponent) can't be added.",
         "PureMouse can't identify it. Choose a different app.")
    }
}
