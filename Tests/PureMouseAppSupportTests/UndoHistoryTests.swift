import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

@MainActor
private struct Rig {
    let sandbox: Sandbox
    let manager = UndoManager()
    let clock = ManualClock()
    let store: ConfigStore

    init(_ json: String = #"{"dpi": 800}"#) throws {
        sandbox = try Sandbox()
        try sandbox.write(json)
        store = ConfigStore(locations: sandbox.locations, clock: clock.clock)
        store.reloadConfig()
        store.keepHistory(on: manager)
    }

    func disk() throws -> ConfigTree { try sandbox.tree() }
}

@MainActor @Test func aChangeRegistersItsInverseAndUndoRedoWriteTheFile() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    #expect(try rig.disk().int(["dpi"]) == 1600)
    #expect(rig.manager.canUndo)
    #expect(rig.manager.undoActionName == "Pointer Speed")

    rig.manager.undo()
    #expect(try rig.disk().int(["dpi"]) == 800)
    #expect(rig.store.config.int(["dpi"]) == 800)
    #expect(rig.manager.canRedo)
    #expect(rig.manager.redoActionName == "Pointer Speed")

    rig.manager.redo()
    #expect(try rig.disk().int(["dpi"]) == 1600)
    #expect(rig.manager.undoActionName == "Pointer Speed")
}

@MainActor @Test func undoRestoresAKeyThatWasAbsent() throws {
    let rig = try Rig(#"{"dpi": 800, "future": {"x": 1}}"#)
    rig.store.set(true, at: ["scrollWheel", "inverted"])
    #expect(rig.manager.undoActionName == "Reverse Direction")
    rig.manager.undo()
    let disk = try rig.disk()
    #expect(!disk.contains(["scrollWheel"]))
    #expect(disk.int(["future", "x"]) == 1)
    #expect(disk.int(["dpi"]) == 800)
}

@MainActor @Test func anEditThatChangesNothingRegistersNothing() throws {
    let rig = try Rig()
    rig.store.set(800, at: ["dpi"])
    rig.store.update { _ in }
    #expect(!rig.manager.canUndo)
}

@MainActor @Test func debouncedWritesBeforeTheFlushAreOneStep() throws {
    let rig = try Rig()
    rig.store.set(0.5, at: ["smoothScroll", "speed"], debounce: true)
    rig.store.set(0.7, at: ["smoothScroll", "speed"], debounce: true)
    rig.store.set(0.9, at: ["smoothScroll", "speed"], debounce: true)
    rig.clock.advance(ConfigStore.debounce)
    #expect(try rig.disk().double(["smoothScroll", "speed"]) == 0.9)
    #expect(rig.manager.undoActionName == "Scrolling Speed")

    rig.manager.undo()
    #expect(!rig.manager.canUndo)
    #expect(try rig.disk().contains(["smoothScroll", "speed"]) == false)
    #expect(rig.store.config.double(["smoothScroll", "speed"]) == 1)  // the default set's
    rig.manager.redo()
    #expect(try rig.disk().double(["smoothScroll", "speed"]) == 0.9)
}

@MainActor @Test func aSecondDragAfterTheFlushIsAnotherStep() throws {
    let rig = try Rig()
    rig.store.set(0.5, at: ["smoothScroll", "speed"], debounce: true)
    rig.clock.advance(ConfigStore.debounce)
    rig.store.set(0.7, at: ["smoothScroll", "speed"], debounce: true)
    rig.clock.advance(ConfigStore.debounce)
    rig.manager.undo()
    #expect(try rig.disk().double(["smoothScroll", "speed"]) == 0.5)
    rig.manager.undo()
    #expect(try rig.disk().contains(["smoothScroll", "speed"]) == false)
}

@MainActor @Test func aDragStillWaitingIsUndoneAsWhole() throws {
    let rig = try Rig()
    rig.store.set(0.5, at: ["smoothScroll", "speed"], debounce: true)
    rig.store.set(0.7, at: ["smoothScroll", "speed"], debounce: true)
    rig.manager.undo()
    #expect(rig.store.config.double(["smoothScroll", "speed"]) == 1)
    #expect(try rig.disk().contains(["smoothScroll", "speed"]) == false)
    #expect(!rig.manager.canUndo)
}

@MainActor @Test func anImmediateChangeClosesTheStepBeforeIt() throws {
    let rig = try Rig()
    rig.store.set(0.5, at: ["smoothScroll", "speed"], debounce: true)
    rig.store.set(1600, at: ["dpi"])
    rig.store.set(0.7, at: ["smoothScroll", "speed"], debounce: true)
    rig.clock.advance(ConfigStore.debounce)
    rig.manager.undo()  // the second drag
    #expect(try rig.disk().double(["smoothScroll", "speed"]) == 0.5)
    #expect(try rig.disk().int(["dpi"]) == 1600)
    rig.manager.undo()
    #expect(try rig.disk().int(["dpi"]) == 800)
    rig.manager.undo()
    #expect(try rig.disk().contains(["smoothScroll", "speed"]) == false)
}

@MainActor @Test func undoKeepsAHandEditMadeMeanwhile() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    // A hand edit of another key is an external change: the stacks go (next test); an undo
    // replays only its own keys onto the file as it is.
    rig.store.set(true, at: ["scrollWheel", "inverted"])
    try rig.sandbox.write(#"{"dpi": 1600, "scrollWheel": {"inverted": true}, "buttons": {"back": "appExpose"}}"#)
    rig.manager.undo()
    #expect(try rig.disk().string(["buttons", "back"]) == "appExpose")
}

// MARK: Names

@MainActor private func name(_ json: String = "{}", _ edit: (inout ConfigTree) -> Void) throws -> String? {
    let rig = try Rig(json)
    rig.store.update(edit)
    return rig.manager.undoActionName
}

@MainActor @Test func stepNamesFollowTheChangedKey() throws {
    #expect(try name { $0.set(1600, at: ["dpi"]) } == "Pointer Speed")
    #expect(try name { $0.set([800, 1600], at: ["dpiPresets"]) } == "Presets")
    #expect(try name { $0.set(2.0, at: ["smoothScroll", "speed"]) } == "Scrolling Speed")
    #expect(try name { $0.set(2.0, at: ["smoothScroll", "acceleration"]) } == "Acceleration")
    #expect(try name { $0.set(200, at: ["smoothScroll", "smoothingMs"]) } == "Glide")
    #expect(try name { $0.apply(.gliding) } == "Feel")
    #expect(try name { $0.set(false, at: ["smoothScroll", "enabled"]) } == "Smooth Scrolling")
    #expect(try name { $0.set(true, at: ["scrollWheel", "inverted"]) } == "Reverse Direction")
    #expect(try name { $0.set("freespin", at: ["scrollWheel", "mode"]) } == "Wheel Mode")
    #expect(try name { $0.set(20, at: ["scrollWheel", "smartShiftThreshold"]) } == "SmartShift")
    #expect(try name { $0.set("volume", at: ["thumbWheel", "action"]) } == "Thumb Wheel")
    #expect(try name { $0.set(true, at: ["thumbWheel", "inverted"]) } == "Thumb Wheel")
    #expect(try name { $0.set(2.0, at: ["smoothScroll", "horizontalSpeed"]) } == "Thumb Wheel")
    #expect(try name { $0.set("appExpose", at: ["buttons", "back"]) } == "Button Action")
    #expect(try name { $0.set(8, at: ["gesture", "distanceMm"]) } == "Hold and Move")
    #expect(try name { $0.set(false, at: ["notifications", "lowBattery"]) } == "Low Battery Notification")
    #expect(try name { $0.set(false, at: ["universalControl", "handOff"]) } == "Universal Control")
}

@MainActor @Test func aDeviceOrAppPathIsNamedByWhatIsAfterIt() throws {
    #expect(try name { $0.set(1600, at: ["devices", "mx master 3s", "dpi"]) } == "Pointer Speed")
    #expect(try name { $0.set(1600, at: ["devices", "mx master 3s", "dpi"]); $0.set("MX Master 3S", at: ["devices", "mx master 3s", "name"]) }
        == "Pointer Speed")
    #expect(try name { $0.set("volume", at: ["apps", "com.apple.Music", "thumbWheel", "action"]) } == "Thumb Wheel")
    #expect(try name { $0.set(2.0, at: ["apps", "com.microsoft.Excel", "smoothScroll", "speed"]) } == "Scrolling Speed")
}

@MainActor @Test func aWholeAppEntryIsAppSettings() throws {
    #expect(try name { $0.set([:] as [String: Any], at: ["apps", "com.apple.Music"]) } == "App Settings")
    let json = #"{"apps": {"com.apple.Music": {"thumbWheel": {"action": "volume"}, "buttons": {"back": "appExpose"}}}}"#
    #expect(try name(json) { $0.set(nil, at: ["apps", "com.apple.Music"]) } == "App Settings")
    #expect(try name { $0.set("volume", at: ["apps", "a", "thumbWheel", "action"]); $0.set(2.0, at: ["apps", "a", "smoothScroll", "speed"]) }
        == "App Settings")
    // One setting inside an app that stays is named for the setting.
    #expect(try name(json) { $0.set(nil, at: ["apps", "com.apple.Music", "buttons", "back"]) } == "Button Action")
}

@MainActor @Test func anythingMixedIsChanges() throws {
    #expect(try name { $0.set(1600, at: ["dpi"]); $0.set(true, at: ["scrollWheel", "inverted"]) } == "Changes")
    #expect(try name { $0.set(2.0, at: ["smoothScroll", "speed"]); $0.set(200, at: ["smoothScroll", "smoothingMs"]) } == "Changes")
    #expect(try name { $0.set(true, at: ["somethingElse"]) } == "Changes")
    // Restoring what the file never held changes nothing, so there is nothing to undo.
    #expect(try name { $0.restoreScrollingDefaults() } == "")
}

// MARK: Clearing

@MainActor @Test func anExternalChangeClearsBothStacks() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    rig.store.set(true, at: ["scrollWheel", "inverted"])
    rig.manager.undo()
    #expect(rig.manager.canUndo && rig.manager.canRedo)
    try rig.sandbox.write(#"{"dpi": 3200}"#)
    rig.store.reloadConfig()
    #expect(!rig.manager.canUndo && !rig.manager.canRedo)
    #expect(rig.store.config.int(["dpi"]) == 3200)
}

@MainActor @Test func itsOwnWriteComingBackKeepsTheStacks() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    rig.store.reloadConfig()
    rig.manager.undo()
    rig.store.reloadConfig()
    #expect(rig.manager.canRedo)
}

@MainActor @Test func aDeletedFileClearsBothStacks() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    try FileManager.default.removeItem(at: rig.sandbox.config)
    rig.store.reloadConfig()
    #expect(!rig.manager.canUndo)
}

@MainActor @Test func resetAllClearsBothStacks() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    rig.store.set(true, at: ["scrollWheel", "inverted"])
    rig.manager.undo()
    rig.store.resetAll()
    #expect(!rig.manager.canUndo && !rig.manager.canRedo)
}

@MainActor @Test func useLastWorkingConfigClearsBothStacks() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    try rig.sandbox.write("{ broken")
    rig.store.reloadConfig()
    #expect(rig.store.canRestoreLastWorking)
    rig.store.restoreLastWorking()
    #expect(!rig.manager.canUndo && !rig.manager.canRedo)
    // And the store takes new changes again.
    rig.store.set(2400, at: ["dpi"])
    #expect(rig.manager.canUndo)
}

@MainActor @Test func aFailedWriteClearsBothStacks() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    rig.store.set(true, at: ["scrollWheel", "inverted"])
    rig.manager.undo()
    #expect(rig.manager.canUndo && rig.manager.canRedo)
    // The file is replaced by one that does not load, behind the store's back.
    try rig.sandbox.write("{ broken")
    rig.store.set(3200, at: ["dpi"])
    #expect(rig.store.writeError != nil)
    #expect(!rig.manager.canUndo && !rig.manager.canRedo)
}

@MainActor @Test func aWriteThatFailsWhileUndoingClearsTheStacks() throws {
    let rig = try Rig()
    rig.store.set(1600, at: ["dpi"])
    try rig.sandbox.write("{ broken")
    rig.manager.undo()
    #expect(rig.store.writeError != nil)
    #expect(!rig.manager.canUndo && !rig.manager.canRedo)
}

// MARK: No history

@MainActor @Test func theMenuBarAppsModelKeepsNoHistory() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800}"#)
    let model = AppModel(locations: sandbox.locations, defaults: UserDefaults(suiteName: "pm-\(UUID().uuidString)")!, alert: { _, _ in })
    #expect(model.undoManager == nil)
    #expect(model.store.undo == nil)
    model.set(1600, at: ["dpi"])
    #expect(try sandbox.tree().int(["dpi"]) == 1600)
}

@MainActor @Test func aModelGivenAnUndoManagerRegistersOnIt() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800}"#)
    let manager = UndoManager()
    let model = AppModel(locations: sandbox.locations, defaults: UserDefaults(suiteName: "pm-\(UUID().uuidString)")!,
                         alert: { _, _ in }, undoManager: manager)
    model.setDPI(1600)
    #expect(manager.undoActionName == "Pointer Speed")
    manager.undo()
    #expect(try sandbox.tree().int(["dpi"]) == 800)
}
