import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

@MainActor
private func loadedStore(_ sandbox: Sandbox, clock: Clock? = nil) -> ConfigStore {
    let store = ConfigStore(locations: sandbox.locations, clock: clock ?? ManualClock().clock)
    store.reloadConfig()
    return store
}

@MainActor @Test func storeEditsSaveOnlyTheirKeys() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800, "future": {"x": 1}}"#)
    let store = loadedStore(sandbox)
    #expect(store.config.int(["dpi"]) == 800)
    store.set(true, at: ["scrollWheel", "inverted"])
    let disk = try sandbox.tree()
    #expect(disk.bool(["scrollWheel", "inverted"]) == true)
    #expect(disk.int(["future", "x"]) == 1)
    #expect(disk.int(["dpi"]) == 800)
    #expect(!store.hasPendingChanges)
    // Its own write reads back as a no-op.
    store.reloadConfig()
    #expect(store.config.bool(["scrollWheel", "inverted"]) == true)
}

@MainActor @Test func flushKeepsAHandEditMadeBetweenLoadAndSave() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800, "buttons": {"back": "missionControl"}}"#)
    let manual = ManualClock()
    let store = loadedStore(sandbox, clock: manual.clock)
    store.set(1.5, at: ["smoothScroll", "speed"], debounce: true)
    #expect(store.hasPendingChanges)
    #expect(try sandbox.tree().contains(["smoothScroll"]) == false)
    // Edited by hand before the debounced write.
    try sandbox.write(#"{"dpi": 1200, "buttons": {"back": "appExpose", "forward": "showDesktop"}}"#)
    store.flush()
    let disk = try sandbox.tree()
    #expect(disk.double(["smoothScroll", "speed"]) == 1.5)
    #expect(disk.int(["dpi"]) == 1200)
    #expect(disk.string(["buttons", "back"]) == "appExpose")
    #expect(disk.string(["buttons", "forward"]) == "showDesktop")
    #expect(store.config.int(["dpi"]) == 1200)
    // The debounce had nothing left to do.
    manual.advance(ConfigStore.debounce)
    #expect(try sandbox.tree().int(["dpi"]) == 1200)
}

@MainActor @Test func aDebouncedEditWritesOnceTheClockRuns() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800}"#)
    let manual = ManualClock()
    let store = loadedStore(sandbox, clock: manual.clock)
    store.set(0.5, at: ["smoothScroll", "speed"], debounce: true)
    store.set(0.7, at: ["smoothScroll", "speed"], debounce: true)
    #expect(manual.pending.count == 1)
    manual.advance(ConfigStore.debounce)
    #expect(try sandbox.tree().double(["smoothScroll", "speed"]) == 0.7)
}

@MainActor @Test func aReloadWhileAnEditWaitsSavesItOnTopOfTheHandEdit() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800}"#)
    let store = loadedStore(sandbox)
    store.set(true, at: ["scrollWheel", "inverted"], debounce: true)
    try sandbox.write(#"{"dpi": 1600}"#)
    store.reloadConfig()
    let disk = try sandbox.tree()
    #expect(disk.int(["dpi"]) == 1600)
    #expect(disk.bool(["scrollWheel", "inverted"]) == true)
    #expect(!store.hasPendingChanges)
}

@MainActor @Test func aBrokenFileMakesTheStoreReadOnlyAndOffersTheLastWorking() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800}"#)
    let store = loadedStore(sandbox)
    #expect(!store.readOnly && !store.canRestoreLastWorking)
    let broken = #"{"dpi": 800,"#
    try sandbox.write(broken)
    store.reloadConfig()
    #expect(store.configProblem != nil)
    #expect(store.readOnly)
    #expect(store.canRestoreLastWorking)
    store.set(1600, at: ["dpi"])
    store.flush()
    #expect(try sandbox.read() == broken)
    #expect(!store.hasPendingChanges)
    store.restoreLastWorking()
    #expect(try sandbox.tree().int(["dpi"]) == 800)
    #expect(!store.readOnly)
    #expect(store.config.int(["dpi"]) == 800)
}

@MainActor @Test func aFileTheDecoderRejectsIsAnErrorToo() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 999999}"#)
    let store = loadedStore(sandbox)
    #expect(store.readOnly)
    // Never loaded, so nothing to restore.
    #expect(!store.canRestoreLastWorking)
}

@MainActor @Test func theDaemonsComplaintMakesTheStoreReadOnly() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800}"#)
    let store = loadedStore(sandbox)
    store.daemonConfigError = { "rejected" }
    #expect(store.readOnly && store.configError == "rejected")
    store.set(1600, at: ["dpi"])
    #expect(try sandbox.tree().int(["dpi"]) == 800)
}

@MainActor @Test func anEditTheDecoderRejectsIsNotSaved() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800}"#)
    let store = loadedStore(sandbox)
    store.set(999_999, at: ["dpi"])
    #expect(store.writeError != nil)
    #expect(try sandbox.tree().int(["dpi"]) == 800)
    #expect(store.config.int(["dpi"]) == 800)
}

@MainActor @Test func resetEmptiesTheFileAndDropsPendingEdits() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{"dpi": 800}"#)
    let manual = ManualClock()
    let store = loadedStore(sandbox, clock: manual.clock)
    store.set(1600, at: ["dpi"], debounce: true)
    store.resetAll()
    #expect(try sandbox.tree().root.isEmpty)
    #expect(store.config.root as NSDictionary == ConfigTree.defaults.root as NSDictionary)
    #expect(!store.hasPendingChanges)
    #expect(manual.pending.isEmpty)
}

@MainActor @Test func aMissingFileIsEveryDefaultAndAnEditCreatesIt() throws {
    let sandbox = try Sandbox()
    let store = loadedStore(sandbox)
    #expect(store.config.root as NSDictionary == ConfigTree.defaults.root as NSDictionary && !store.readOnly)
    store.set(1600, at: ["dpi"])
    #expect(try sandbox.tree().int(["dpi"]) == 1600)
}

@MainActor @Test func flushTellsItsCallerEvenWithNothingToWrite() throws {
    let sandbox = try Sandbox()
    let store = loadedStore(sandbox)
    var flushes = 0
    store.flushed = { flushes += 1 }
    store.flush()
    #expect(flushes == 1)
    #expect(!sandbox.exists(sandbox.config))
}
