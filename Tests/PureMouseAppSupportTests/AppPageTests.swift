import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

// An app's settings page (#137): how it opens, what its segments hold, what a change writes, and
// which value an app that leaves a setting alone inherits. That value is what the known mice
// resolve (top level, then the mouse's entry), so a mouse with its own setting shows its own, and
// mice that differ say "Varies by Mouse". Kit's decoder is the oracle: it layers an app over a
// mouse (`Config.forDevice(_:)`, then `decodeApps`).

private let mx = "mb03400000000"
private let m750 = "pb02c"

private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }
private func decode(_ config: ConfigTree) throws -> Config { try JSONDecoder().decode(Config.self, from: config.data()) }
private func mouse(_ key: String) -> ConfigScope { ConfigScope.device(key)! }

/// The button 0x0053 ("back") as the daemon resolves it for `app` on the mouse with `key`.
private func kitBack(_ config: ConfigTree, mouse key: String, app: String) throws -> Action? {
    let settings = try #require(try decode(config).forDevice(key).settings(forApp: app))
    if case .action(let action)? = settings.bindings[0x0053] { return action }
    return nil
}

/// What the page writes, as the entries (`apps.<id>`) holding a key that differs.
private func changed(_ before: ConfigTree, _ after: ConfigTree) -> Set<String> {
    Set(before.changes(to: after).map { $0.path.prefix(2).joined(separator: ".") })
}

@Suite struct AppPageTests {
    // MARK: 1. Opening and leaving

    @Test func aRowAndTheMenuRequestOpenTheSamePage() throws {
        let config = try tree(#"{"apps": {"com.apple.Safari": {"buttons": {"back": "mute"}}}}"#)
        // A row of the list.
        var row = AppList()
        row.show("com.apple.Safari")
        // "Settings for Safari…": the menu's request names the app, whatever case the bundle ID has.
        let request = try #require(ShowRequest(body: ShowRequest(app: "com.apple.safari").body).app)
        var menu = AppList()
        menu.add(request, in: config)
        #expect(row.open == "com.apple.Safari" && menu.open == "com.apple.Safari")
        #expect(row.segment == .buttons && menu.segment == .buttons)
        #expect(ShowRequest(app: "com.apple.safari").pane == .tab(.apps))
    }

    @Test func backReturnsToTheListAndKeepsWhatWasAdded() throws {
        let config = try tree(#"{}"#)
        var list = AppList()
        list.add("com.example.Notes", in: config)
        list.select(.scrolling)
        list.close()
        #expect(list.open == nil)
        #expect(list.ids(in: config) == ["com.example.Notes"])
        // The next app opens on Buttons again.
        list.show("com.example.Notes")
        #expect(list.segment == .buttons)
    }

    // MARK: 2. Segments

    @Test func selectingASegmentWritesNothing() throws {
        let config = try tree(#"{"buttons": {"back": "mute"}, "apps": {"a.b": {"buttons": {"back": "zoomIn"}}}}"#)
        let before = config.data()
        var list = AppList()
        list.add("a.b", in: config)
        list.select(.scrolling)
        list.select(.buttons)
        #expect(config.data() == before)
        #expect(list.added.isEmpty)
    }

    @Test func thereIsNoPointerSegmentAndTheThumbWheelIsUnderScrolling() {
        #expect(AppSegment.allCases == [.buttons, .scrolling])
        #expect(AppSegment.allCases.map(\.title) == ["Buttons", "Scrolling"])
        #expect(AppSegment.buttons.sections == [.buttons])
        #expect(AppSegment.scrolling.sections == [.customScrolling, .thumbWheel])
    }

    // MARK: 3. Writes stay under the app

    @Test func aChangeAndItsResetTouchOnlyThatAppsKeys() throws {
        let start = try tree("""
            {"buttons": {"back": "mute"}, "dpi": 1200,
             "devices": {"\(mx)": {"name": "MX", "buttons": {"back": "zoomIn"}}},
             "apps": {"other.app": {"buttons": {"back": "zoomOut"}}}}
            """)
        var config = start
        config.bindInApp("a.b", button: "back", to: .named("missionControl"))
        #expect(changed(start, config) == ["apps.a.b"])
        config.setOverridesScrolling("a.b", true, inheriting: [mouse(mx)])
        config.chooseThumbWheel(.preset("tabs"), at: ["apps", "a.b", "thumbWheel"])
        #expect(changed(start, config).allSatisfy { $0.hasPrefix("apps.a.b") })
        // Resetting each row removes the keys it set, and the app's entry with the last one.
        config.bindInApp("a.b", button: "back", to: .standard)
        config.setOverridesScrolling("a.b", false)
        config.chooseThumbWheel(.inherit, at: ["apps", "a.b", "thumbWheel"])
        #expect(changed(start, config).isEmpty)
        #expect(config.data() == start.data())
    }

    @Test func anExplicitValueIsOwnAndMouseDefaultIsDistinctFromInheriting() throws {
        var config = try tree(#"{"buttons": {"back": "mute"}}"#)
        let wider = [ConfigScope.global]
        #expect(config.appButton("a.b", button: "back", inheriting: wider).own == .standard)
        config.bindInApp("a.b", button: "back", to: .mouseDefault)
        let native = config.appButton("a.b", button: "back", inheriting: wider)
        #expect(native.own == .mouseDefault && native.own != .standard)
        #expect(config.isOverridden(["buttons", "back"], in: ConfigTree.appScope("a.b")))
        config.bindInApp("a.b", button: "back", to: .named("zoomIn"))
        #expect(config.appButton("a.b", button: "back", inheriting: wider).own == .named("zoomIn"))
        config.bindInApp("a.b", button: "back", to: .standard)
        #expect(!config.hasApp("a.b"))
    }

    // MARK: 4. Varies by Mouse

    private let twoMice = """
        {"buttons": {"back": "mute"},
         "devices": {"\(mx)": {"name": "MX", "buttons": {"back": "zoomIn"}},
                     "\(m750)": {"name": "M750", "buttons": {"back": "zoomOut"}}}}
        """

    @Test func miceThatResolveAControlDifferentlyVary() throws {
        let config = try tree(twoMice)
        let mice = [mouse(mx), mouse(m750)]
        let back = config.appButton("a.b", button: "back", inheriting: mice)
        #expect(back.variesByMouse)
        #expect(back.inheritedLabel == "Varies by Mouse" && back.inheritedSpokenLabel == "Varies by Mouse")
        // The same value on every mouse is one value, whoever sets it.
        let same = try tree(#"{"buttons": {"back": "mute"}, "devices": {"mb03400000000": {"buttons": {"back": "mute"}}}}"#)
        let one = same.appButton("a.b", button: "back", inheriting: mice)
        #expect(!one.variesByMouse && one.inheritedLabel == ButtonAction.named("mute").label)
        // A control the mice agree on, in a config where they differ elsewhere.
        #expect(!config.appButton("a.b", button: "forward", inheriting: mice).variesByMouse)
    }

    @Test func resettingRestoresEachMiceOwnFallback() throws {
        var config = try tree(twoMice)
        config.bindInApp("a.b", button: "back", to: .named("missionControl"))
        #expect(try kitBack(config, mouse: mx, app: "a.b") == .missionControl)
        #expect(try kitBack(config, mouse: m750, app: "a.b") == .missionControl)
        config.bindInApp("a.b", button: "back", to: .standard)
        // No app entry is left, so each mouse is the mouse it was: its own binding.
        #expect(!config.hasApp("a.b"))
        let decoded = try decode(config)
        #expect(decoded.forDevice(mx).settings(forApp: "a.b") == nil)
        if case .action(let action)? = decoded.forDevice(mx).bindings[0x0053] { #expect(action == .zoomIn) } else { Issue.record("mx") }
        if case .action(let action)? = decoded.forDevice(m750).bindings[0x0053] { #expect(action == .zoomOut) } else { Issue.record("m750") }
    }

    @Test func variesAlsoCoversGestureDirectionsAndTheThumbWheel() throws {
        let config = try tree("""
            {"buttons": {"gesture": {"click": "missionControl", "up": "appExpose"}},
             "devices": {"\(mx)": {"name": "MX", "buttons": {"gesture": {"up": "mute"}},
                                   "thumbWheel": {"action": "volume"}},
                         "\(m750)": {"name": "M750"}}}
            """)
        let mice = [mouse(mx), mouse(m750)]
        let gesture = config.appButton("a.b", button: "gesture", inheriting: mice)
        #expect(gesture.inheritsGesture)
        let up = try #require(gesture.directions.first { $0.name == "up" })
        #expect(up.variesByMouse && up.inheritedLabel == "Varies by Mouse")
        let left = try #require(gesture.directions.first { $0.name == "left" })
        #expect(!left.variesByMouse && left.inheritedLabel == ButtonAction.named("none").label)
        let choice = config.thumbWheelChoice(inheriting: mice)
        #expect(choice.varies)
        #expect(choice.values == [.preset("volume"), .scroll])
    }

    // MARK: 5. The value that applies is the mouse's, not the top level's (the old sheet's bug)

    @Test func theInheritedValueForAMouseWithItsOwnSettingIsTheMouses() throws {
        let config = try tree("""
            {"buttons": {"back": "mute"},
             "devices": {"\(mx)": {"name": "MX", "buttons": {"back": "zoomIn"}}}}
            """)
        // What the daemon does for an app that leaves the button alone, on that mouse.
        #expect(try decode(config).forDevice(mx).settings(forApp: "a.b") == nil)  // no app entry yet
        var withApp = config
        withApp.bindInApp("a.b", button: "forward", to: .named("zoomOut"))
        #expect(try kitBack(withApp, mouse: mx, app: "a.b") == .zoomIn)
        let button = config.appButton("a.b", button: "back", inheriting: [mouse(mx)])
        #expect(button.everywhere == .named("zoomIn"))
        #expect(!button.variesByMouse)
        // The top level's value is what the old sheet showed.
        #expect(config.appButton("a.b", button: "back").everywhere == .named("mute"))
    }

    @Test func theInheritedScrollingAndThumbWheelAreTheMouses() throws {
        let config = try tree("""
            {"smoothScroll": {"speed": 1.5, "smoothingMs": 100}, "thumbWheel": {"action": "zoom"},
             "devices": {"\(mx)": {"name": "MX", "smoothScroll": {"speed": 2.5},
                                   "thumbWheel": {"action": "tabs", "reversed": true}}}}
            """)
        let scopes = [mouse(mx)]
        #expect(config.number(["smoothScroll", "speed"], in: scopes[0], default: 1) == 2.5)
        #expect(config.number(["smoothScroll", "smoothingMs"], in: scopes[0], default: 125) == 100)
        let choice = config.thumbWheelChoice(inheriting: scopes)
        #expect(!choice.varies && choice.first == .preset("tabs"))
        let state = config.thumbWheelState(inheriting: scopes)
        #expect(state.first.reversed)
        // The top level's wheel, which the old sheet read.
        #expect(config.thumbWheelChoice(at: ["thumbWheel"]) == .preset("zoom"))
        // Turning Custom scrolling on starts from the mouse's values.
        var edited = config
        edited.setOverridesScrolling("a.b", true, inheriting: scopes)
        #expect(edited.double(["apps", "a.b", "smoothScroll", "speed"]) == 2.5)
        #expect(edited.double(["apps", "a.b", "smoothScroll", "smoothingMs"]) == 100)
    }

    @Test func noMiceKnownMeansTheTopLevel() throws {
        let config = try tree(#"{"buttons": {"back": "mute"}}"#)
        #expect(config.appButton("a.b", button: "back", inheriting: []).everywhere == .named("mute"))
    }

    // MARK: 6. The list names the areas an app changes

    @Test func eachRowNamesTheAreasItsAppChanges() throws {
        let config = try tree("""
            {"apps": {"a.b": {"thumbWheel": {"action": "tabs"}, "buttons": {"back": "mute", "top": "zoomIn"},
                              "smoothScroll": {"speed": 2}},
                      "c.d": {"buttons": {"back": "mute"}},
                      "e.f": {"thumbWheel": {"reversed": true}},
                      "g.h": {"smoothScroll": {"smoothingMs": 50}}}}
            """)
        #expect(config.appSummary("a.b") == "Buttons, Scrolling")
        #expect(config.appSummary("c.d") == "Buttons")
        #expect(config.appSummary("e.f") == "Scrolling")
        #expect(config.appSummary("g.h") == "Scrolling")
        #expect(config.appSummary("none.here") == AppList.noCustomSettings)
        #expect(config.appAreas("a.b") == [.buttons, .scrolling])
    }

    // MARK: Fix round: the mice are compared by what they resolve, not by the kind of choice

    @Test func miceWithDifferentCustomThumbWheelActionsVary() throws {
        let config = try tree("""
            {"devices": {"\(mx)": {"name": "MX", "thumbWheel": {"left": "zoomOut", "right": "zoomIn"}},
                         "\(m750)": {"name": "M750", "thumbWheel": {"left": "mute", "right": "zoomIn"}}}}
            """)
        let mice = [mouse(mx), mouse(m750)]
        // Both resolve to Custom, so the choice alone does not tell them apart.
        #expect(!config.thumbWheelChoice(inheriting: mice).varies)
        #expect(config.thumbWheelVaries(inheriting: mice))
        #expect(config.thumbWheelAction("left", inheriting: mice).varies)
        #expect(!config.thumbWheelAction("right", inheriting: mice).varies)
        #expect(config.thumbWheelAction("right", inheriting: mice).first == .named("zoomIn"))
        // The same actions on both mice are one thumb wheel.
        let same = try tree("""
            {"devices": {"\(mx)": {"name": "MX", "thumbWheel": {"left": "zoomOut", "right": "zoomIn"}},
                         "\(m750)": {"name": "M750", "thumbWheel": {"left": "zoomOut", "right": "zoomIn"}}}}
            """)
        #expect(!same.thumbWheelVaries(inheriting: mice))
        // Different kinds of choice still vary.
        let kinds = try tree(#"{"devices": {"\#(mx)": {"name": "MX", "thumbWheel": {"action": "zoom"}}}}"#)
        #expect(kinds.thumbWheelVaries(inheriting: mice))
    }

    @Test func aResetSpeedVariesWhileTheMiceDiffer() throws {
        let config = try tree("""
            {"devices": {"\(mx)": {"name": "MX", "smoothScroll": {"speed": 2}},
                         "\(m750)": {"name": "M750", "smoothScroll": {"speed": 1.5}}},
             "apps": {"a.b": {"smoothScroll": {"smoothingMs": 50}}}}
            """)
        let mice = [mouse(mx), mouse(m750)]
        // Speed is not the app's own (only Glide is), so it follows the mice, which differ.
        #expect(!config.contains(["apps", "a.b", "smoothScroll", "speed"]))
        let speed = config.appliedNumber(["smoothScroll", "speed"], inheriting: mice, default: 1)
        #expect(speed.varies && speed.values == [2, 1.5])
        let agreed = config.appliedNumber(["smoothScroll", "smoothingMs"], inheriting: mice, default: 125)
        #expect(!agreed.varies && agreed.first == 125)
    }

    @Test func startingAGestureInAnAppSeedsItFromWhatTheMouseShows() throws {
        // Global Back is Mute, the mouse's is Zoom In: the page shows Zoom In.
        let config = try tree("""
            {"buttons": {"back": "mute"},
             "devices": {"\(mx)": {"name": "MX", "buttons": {"back": "zoomIn"}}}}
            """)
        var edited = config
        edited.bindInApp("a.b", button: "back", to: .gesture, inheriting: [mouse(mx)])
        #expect(edited.string(["apps", "a.b", "buttons", "back", "click"]) == "zoomIn")
        // The daemon agrees: on that mouse the click is what the page showed, not the top level's.
        let settings = try #require(try decode(edited).forDevice(mx).settings(forApp: "a.b"))
        guard case .gesture(let gesture)? = settings.bindings[0x0053] else { Issue.record("not a gesture"); return }
        #expect(gesture.click == .zoomIn)
        // With no mouse known, the top level is what shows, and what seeds.
        var global = config
        global.bindInApp("a.b", button: "back", to: .gesture)
        #expect(global.string(["apps", "a.b", "buttons", "back", "click"]) == "mute")
        // A mouse that binds the button to Mouse Default seeds a click that does nothing there.
        var native = try tree(#"{"buttons": {"back": "mute"}, "devices": {"\#(mx)": {"name": "MX", "buttons": {"back": "default"}}}}"#)
        native.bindInApp("a.b", button: "back", to: .gesture, inheriting: [mouse(mx)])
        #expect(native.string(["apps", "a.b", "buttons", "back", "click"]) == "none")
    }
}
