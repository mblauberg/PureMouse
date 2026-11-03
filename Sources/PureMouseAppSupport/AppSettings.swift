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

    /// Binds a button's click in one app (`bindClick`): `.standard` gives it back to the mice,
    /// `.mouseDefault` writes `"default"`, so the button is native in the app whatever is bound
    /// wider, and `.gesture` is Hold and Move (`bindHoldAndMove`). What the button does where the
    /// app leaves it alone is what the first of the `inheriting` scopes resolves
    /// (`AppModel.appInheritedScopes`), the value the app's page shows.
    public mutating func bindInApp(_ app: String, button: String, to binding: ButtonAction,
                                   inheriting: [ConfigScope] = [.global]) {
        bindClick(button, to: binding, in: Self.appScope(app), inheriting: inheriting)
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
    /// At the top level, the binding alone. A table's triggers inherit one by one (`AppButton.Trigger`).
    public func scopedButton(_ button: String, in scope: ConfigScope, inheriting: [ConfigScope] = [.global]) -> AppButton {
        let own = binding(button, in: scope)
        guard scope != .global else {
            let triggers = own == .gesture
                ? Gesture.triggers.map { AppButton.Trigger(name: $0, own: gestureBinding(button, $0), everywhere: nil) } : []
            return AppButton(own: own, everywhere: .standard, triggers: triggers, isTopLevel: true)
        }
        let wider = inheriting.isEmpty ? [ConfigScope.global] : inheriting
        let bindings = wider.map { resolvedBinding(button, in: $0) }
        let everywhere = Applied(bindings)
        // A bare action of the scope's own replaces a wider table, so it has no triggers.
        guard own == .gesture || (own == .standard && bindings.contains(.gesture)) else {
            return AppButton(own: own, everywhere: everywhere.first, triggers: [], variesByMouse: everywhere.varies)
        }
        let triggers = Gesture.triggers.map { trigger in
            let inherited: [ButtonAction?] = zip(wider, bindings).map { scope, binding in
                binding == .gesture ? resolvedGestureBinding(button, trigger, in: scope) : nil
            }
            let none = ButtonAction.named("none")
            let effective = inherited.map { $0 == nil || $0 == .standard ? none : $0! }
            return AppButton.Trigger(name: trigger, own: gestureBinding(button, trigger, in: scope),
                                     everywhere: inherited[0], variesByMouse: Applied(effective).varies)
        }
        return AppButton(own: own, everywhere: everywhere.first, triggers: triggers, variesByMouse: everywhere.varies)
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

/// A button as its row shows it, on an app's page, a mouse's or All Mice: the scope's own binding
/// and the one the wider scopes resolve, which applies while the scope leaves the button alone (`own`
/// is `.standard`). A trigger table's rows (ADR 24): the pop-up holds the click, and Double-click and
/// Hold (Hold and Move's directions under it) are child rows once they do something or are set here.
public struct AppButton: Equatable, Sendable {
    /// One trigger of a table: the scope's own (`.standard` when it leaves it out) and, when the
    /// wider scope's binding is a table, its trigger, which applies while the scope's is unset.
    public struct Trigger: Equatable, Sendable {
        public let name: String
        public let own: ButtonAction
        /// nil at the top level, or where the wider binding is no table.
        public let everywhere: ButtonAction?
        /// The mice resolve this trigger differently.
        public var variesByMouse = false

        /// What the row shows while the scope leaves the trigger out.
        public var inheritedLabel: String { variesByMouse ? Applied<ButtonAction>.variesLabel : inherited.triggerLabel }
        public var inheritedSpokenLabel: String { variesByMouse ? Applied<ButtonAction>.variesLabel : inherited.spokenLabel }

        /// The scope sets this trigger itself, whether or not a wider table has one.
        public var isOwn: Bool { own != .standard }

        /// What applies while the scope leaves the trigger out: the wider table's, else nothing; for
        /// the click, the mouse's own (Mouse Default), since a table with no click leaves it so.
        public var inherited: ButtonAction {
            guard let everywhere, everywhere != .standard else { return name == "click" ? .standard : .named("none") }
            return everywhere
        }
    }

    /// Where the child rows' values come from: Hold is its own action, or Hold and Move.
    public struct Child: Equatable, Sendable {
        public let name: String
        /// The scope's own value, `.standard` when it leaves the trigger out; Hold and Move is `.gesture`.
        public let own: ButtonAction
        /// What applies while it does: the wider table's, else nothing.
        public let inherited: ButtonAction
        public var variesByMouse = false

        public var effective: ButtonAction { own != .standard ? own : inherited }
        /// The trigger does something.
        public var isSet: Bool { effective != .standard && effective != .named("none") }
        public var inheritedLabel: String {
            variesByMouse ? Applied<ButtonAction>.variesLabel : inherited.triggerLabel
        }
        public var inheritedSpokenLabel: String {
            variesByMouse ? Applied<ButtonAction>.variesLabel : inherited.triggerSpokenLabel
        }
    }

    public let own: ButtonAction
    public let everywhere: ButtonAction
    /// The table's triggers, when the button is a table here: its own, or the wider one it
    /// inherits (nothing set here). Empty otherwise.
    public let triggers: [Trigger]
    /// The mice resolve the button differently, so `everywhere` is only the first one's.
    public var variesByMouse = false
    /// All Mice: nothing is wider, so a trigger is shown only while it does something.
    public var isTopLevel = false

    public func trigger(_ name: String) -> Trigger? { triggers.first { $0.name == name } }

    /// What the row shows while the scope leaves the button alone: the value the mice share, else
    /// "Varies by Mouse".
    public var inheritedLabel: String { variesByMouse ? Applied<ButtonAction>.variesLabel : everywhere.label }
    public var inheritedSpokenLabel: String { variesByMouse ? Applied<ButtonAction>.variesLabel : everywhere.spokenLabel }

    // MARK: Click

    /// The pop-up's value: the click. `.standard` while the scope leaves it to the wider scope. A
    /// table that names no click, with none wider showing through, reads Mouse Default: a quick tap is
    /// the mouse's own (`.mouseDefault` on a mouse or in an app, where it is a value of its own).
    public var click: ButtonAction {
        guard own == .gesture, let click = trigger("click") else { return own }
        if click.isOwn { return click.own }
        if !clickLeftToMouse { return .standard }
        return isTopLevel ? .standard : .mouseDefault
    }

    /// The scope's table names no click and no wider table gives it one, so a quick tap is the mouse's.
    public var clickLeftToMouse: Bool { canLeaveClickToMouse && trigger("click")?.isOwn == false }

    /// The scope's own table can hand the click to the mouse by leaving it out: no wider table names
    /// one that would show through (`ConfigTree.bindClick`, Mouse Default).
    public var canLeaveClickToMouse: Bool {
        guard own == .gesture, let click = trigger("click") else { return false }
        return click.everywhere == nil || click.everywhere == .standard
    }

    /// What a click does while the scope leaves it: the wider table's click, else the wider binding.
    public var clickInheritedLabel: String {
        guard everywhere == .gesture, !variesByMouse, let click = trigger("click") else { return inheritedLabel }
        return click.variesByMouse ? Applied<ButtonAction>.variesLabel : click.inherited.label
    }

    public var clickInheritedSpokenLabel: String {
        guard everywhere == .gesture, !variesByMouse, let click = trigger("click") else { return inheritedSpokenLabel }
        return click.variesByMouse ? Applied<ButtonAction>.variesLabel : click.inherited.spokenLabel
    }

    /// The click applies in place of the button's own behaviour: what Precise Pointer on the click
    /// is checked against (it owns the button, so no other trigger can be told apart from it).
    public var effectiveClick: ButtonAction {
        guard click == .standard else { return click }
        if everywhere == .gesture { return trigger("click")?.inherited ?? .named("none") }
        return everywhere
    }

    // MARK: Children

    public var doubleClick: Child {
        let trigger = trigger("doubleClick")
        return Child(name: "doubleClick", own: trigger?.own ?? .standard, inherited: trigger?.inherited ?? .named("none"),
                     variesByMouse: trigger?.variesByMouse ?? false)
    }

    /// The Hold row: the scope's `hold`, Hold and Move (`.gesture`) when it sets a direction, and
    /// the wider table's either way while it sets neither (one hold form hides the other).
    public var hold: Child {
        let ownMoves = Gesture.directions.contains { trigger($0)?.isOwn == true }
        let own: ButtonAction = ownMoves ? .gesture : trigger("hold")?.own ?? .standard
        let widerMoves = Gesture.directions.contains { name in
            trigger(name).map { $0.inherited != .named("none") } ?? false
        }
        let inherited: ButtonAction = widerMoves ? .gesture : trigger("hold")?.inherited ?? .named("none")
        let varies = (Gesture.directions + ["hold"]).contains { trigger($0)?.variesByMouse == true }
        return Child(name: "hold", own: own, inherited: inherited, variesByMouse: varies)
    }

    /// Hold and Move's directions, shown under the Hold row while it is Hold and Move.
    public var directions: [Trigger] {
        hold.effective == .gesture ? Gesture.directions.compactMap(trigger) : []
    }

    /// Whether a child row shows: it does something, or (on a mouse or in an app) the scope sets it
    /// itself, "No Action" included.
    public func shows(_ child: Child) -> Bool {
        child.isSet || (!isTopLevel && child.own != .standard)
    }

    /// The child rows that show, in order, before any the user has just added.
    public var children: [Child] { [doubleClick, hold].filter(shows) }

    /// The caption of a collapsed row with children: "Double-click: Mission Control. Hold: Precise
    /// Pointer." nil when there are none, or the mice give one different things while the scope
    /// leaves it alone (the row says "Varies by Mouse", and one mouse's summary would be wrong).
    public var summary: String? {
        let children = children
        guard !children.isEmpty, !children.contains(where: { $0.variesByMouse && $0.own == .standard }) else { return nil }
        return children.map { child in
            if child.name == "hold", child.effective == .gesture {
                let actions = directions.map { $0.isOwn ? $0.own : $0.inherited }
                return "Hold and Move: \(Triggers.directionsSummary(actions))."
            }
            return "\(Gesture.label(child.name)): \(child.effective.triggerLabel)."
        }.joined(separator: " ")
    }

    /// The app leaves the button to a table set in the mice: its rows show as for any inherited
    /// row, and editing one writes only that trigger under the app.
    public var inheritsGesture: Bool { own == .standard && !triggers.isEmpty }
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
