import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

/// The default set (docs/configuration.md, "Defaults") as Settings reads it: no file, `{}`,
/// Reset All Settings and each pane's Restore Defaults all give the one set Kit's decoder lays
/// every file over (`Config.defaultSetJSON`).

@MainActor
private func loadedStore(_ sandbox: Sandbox) -> ConfigStore {
    let store = ConfigStore(locations: sandbox.locations, clock: ManualClock().clock)
    store.reloadConfig()
    return store
}

/// A file with something set in every section the panes own, and a mouse and an app besides.
private let busyFile = #"""
    {"dpi": 1600, "dpiPresets": [800, 1600],
     "smoothScroll": {"enabled": false, "speed": 2, "acceleration": 0.5, "smoothingMs": 60},
     "scrollWheel": {"inverted": true, "mode": "freespin", "smartShiftThreshold": 30},
     "thumbWheel": {"inverted": true, "reversed": true, "action": "zoom"},
     "buttons": {"back": "default", "forward": "mute", "middle": "launchpad",
                 "gesture": {"click": "none", "up": "none", "left": "launchpad"}},
     "gesture": {"distanceMm": 8},
     "devices": {"m123456789abc": {"name": "MX", "dpi": 800}},
     "apps": {"com.apple.Safari": {"buttons": {"top": "nextTab"}}}}
    """#

private func expectDefaultSet(_ config: ConfigTree, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let expected = try ConfigTree(data: Data(Config.defaultSetJSON.utf8))
    #expect(config[["smoothScroll"]] as? NSDictionary == expected[["smoothScroll"]] as? NSDictionary, sourceLocation: sourceLocation)
    #expect(config[["buttons"]] as? NSDictionary == expected[["buttons"]] as? NSDictionary, sourceLocation: sourceLocation)
    #expect(config.smoothScrollEnabled && config.feelSelection == .balanced, sourceLocation: sourceLocation)
    #expect(config.binding("back") == .named("navigateBack"), sourceLocation: sourceLocation)
    #expect(config.binding("forward") == .named("navigateForward"), sourceLocation: sourceLocation)
    #expect(config.binding("gesture") == .gesture, sourceLocation: sourceLocation)
    for (direction, action) in [("click", "missionControl"), ("up", "missionControl"), ("down", "appExpose"),
                                ("left", "spaceLeft"), ("right", "spaceRight")] {
        #expect(config.gestureBinding("gesture", direction) == .named(action), sourceLocation: sourceLocation)
    }
    #expect(config.binding("middle") == .standard && config.binding("top") == .standard, sourceLocation: sourceLocation)
    for key in ["dpi", "scrollWheel"] { #expect(config[[key]] == nil, sourceLocation: sourceLocation) }
}

@MainActor @Test func aMissingFileAndAnEmptyObjectAreTheDefaultSet() throws {
    let missing = try Sandbox()
    try expectDefaultSet(loadedStore(missing).config)
    let empty = try Sandbox()
    try empty.write("{}\n")
    try expectDefaultSet(loadedStore(empty).config)
    // Reading wrote nothing.
    #expect(!FileManager.default.fileExists(atPath: missing.config.path))
    #expect(try empty.read() == "{}\n")
}

@MainActor @Test func feelShowsBalancedOnAFreshConfig() throws {
    let store = loadedStore(try Sandbox())
    #expect(store.config.feelSelection == .balanced && store.config.globalFeel == .balanced)
    #expect(store.config.smoothScrollEnabled(in: .global))
}

@MainActor @Test func resetAllYieldsTheDefaultSetIncludingGestureDirections() throws {
    let sandbox = try Sandbox()
    try sandbox.write(busyFile)
    let store = loadedStore(sandbox)
    #expect(store.config.binding("back") == .standard)  // Mouse Default, as the file says
    store.resetAll()
    try expectDefaultSet(store.config)
    #expect(try sandbox.read() == "{}\n")
}

@MainActor @Test func restoreDefaultsOnEachPaneLeavesItsSectionAtTheDefaultSet() throws {
    let sandbox = try Sandbox()
    try sandbox.write(busyFile)
    let store = loadedStore(sandbox)
    #expect(!store.config.smoothScrollEnabled)

    store.update { $0.restoreScrollingDefaults(in: .global) }
    #expect(store.config.smoothScrollEnabled && store.config.feelSelection == .balanced)
    #expect(store.config[["smoothScroll"]] as? NSDictionary == ConfigTree.defaults[["smoothScroll"]] as? NSDictionary)
    #expect(store.config[["scrollWheel"]] == nil && store.config.string(["thumbWheel", "action"]) == nil)
    // What the pane does not own stays.
    #expect(store.config.int(["dpi"]) == 1600 && store.config.string(["buttons", "forward"]) == "mute")

    store.update { $0.restoreButtonDefaults(in: .global) }
    #expect(store.config[["buttons"]] as? NSDictionary == ConfigTree.defaults[["buttons"]] as? NSDictionary)
    #expect(store.config[["gesture"]] == nil)
    #expect(store.config.binding("back") == .named("navigateBack") && store.config.binding("middle") == .standard)
    #expect(store.config.int(["dpi"]) == 1600)

    store.update { $0.restorePointerDefaults(in: .global) }
    #expect(store.config[["dpi"]] == nil && store.config[["dpiPresets"]] == nil)

    // The file holds only what the user's devices and apps hold.
    let disk = try sandbox.tree()
    #expect(Set(disk.root.keys) == ["devices", "apps"])
    try expectDefaultSet(store.config)
}

@MainActor @Test func mouseDefaultOnBackIsWrittenSoTheDefaultSetDoesNotReturn() throws {
    let sandbox = try Sandbox()
    let store = loadedStore(sandbox)
    store.update { $0.bind("back", to: .standard) }
    #expect(try sandbox.tree().string(["buttons", "back"]) == "default")
    #expect(try decode(sandbox).bindings[0x0053] == nil)
    // And the gesture's "Do Nothing" is written, since leaving the key out gives the direction back.
    store.update { $0.bind("gesture", direction: "up", to: .named("none")) }
    #expect(try sandbox.tree().string(["buttons", "gesture", "up"]) == "none")
    guard case .gesture(let gesture)? = try decode(sandbox).bindings[0x00C3] else { Issue.record("gesture"); return }
    #expect(gesture.up == .none && gesture.down == .appExpose)
}

@MainActor @Test func turningSmoothScrollingOffAndOnWritesOnlyTheSwitch() throws {
    let sandbox = try Sandbox()
    let store = loadedStore(sandbox)
    store.update { $0.smoothScrollEnabled = false }
    #expect(try sandbox.tree().root as NSDictionary == ["smoothScroll": ["enabled": false]] as NSDictionary)
    #expect(try decode(sandbox).smoothScroll?.enabled == false)
    store.update { $0.smoothScrollEnabled = true }
    #expect(try sandbox.read() == "{}\n" || sandbox.tree().root.isEmpty)
    #expect(store.config.smoothScrollEnabled)
}

@MainActor @Test func anEditOnAFreshConfigWritesOnlyTheEditedKey() throws {
    let sandbox = try Sandbox()
    let store = loadedStore(sandbox)
    store.update { $0.apply(.gliding) }
    #expect(try sandbox.tree().root as NSDictionary
            == ["smoothScroll": ["acceleration": 1.2, "smoothingMs": 350]] as NSDictionary)
    #expect(store.config.feelSelection == .gliding)
}

private func decode(_ sandbox: Sandbox) throws -> Config {
    try JSONDecoder().decode(Config.self, from: Data(contentsOf: sandbox.config))
}
