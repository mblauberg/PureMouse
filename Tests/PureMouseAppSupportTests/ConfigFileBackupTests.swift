import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

/// Reset All Settings and Restore Last Working keep the file they replace as `config.json.bak`;
/// Open Config File only ever creates a missing file.
@MainActor
struct ConfigFileBackupTests {
    let sandbox: Sandbox
    let empty = ConfigTree().data()

    init() throws { sandbox = try Sandbox() }

    func loadedStore(clock: Clock = ManualClock().clock) -> ConfigStore {
        let store = ConfigStore(locations: sandbox.locations, clock: clock)
        store.reloadConfig()
        return store
    }

    @Test func resetKeepsThePreviousBytesExactly() throws {
        let previous = "{\n  \"dpi\" : 1600,   \"future\": {\"x\": 1.50}\n}\n"
        try sandbox.write(previous)
        let store = loadedStore()
        store.resetAll()
        #expect(try sandbox.read(sandbox.backup) == previous)
        #expect(try Data(contentsOf: sandbox.config) == empty)
        #expect(store.config.root.isEmpty)
        #expect(store.writeError == nil)
    }

    @Test func resetAndRestoreEachKeepABrokenFile() throws {
        try sandbox.write(#"{"dpi": 800}"#)
        let store = loadedStore()
        let broken = #"{"dpi": 800,"#
        try sandbox.write(broken)
        store.reloadConfig()
        #expect(store.canRestoreLastWorking)

        store.restoreLastWorking()
        #expect(try sandbox.read(sandbox.backup) == broken)
        #expect(try sandbox.tree().int(["dpi"]) == 800)
        #expect(store.configError == nil)

        let brokenAgain = #"{"dpi": 900 "#
        try sandbox.write(brokenAgain)
        store.reloadConfig()
        #expect(store.readOnly)
        store.resetAll()
        #expect(try sandbox.read(sandbox.backup) == brokenAgain)
        #expect(try Data(contentsOf: sandbox.config) == empty)
        #expect(!store.readOnly)
    }

    @Test func nothingToKeepLeavesAnEarlierBackupAlone() throws {
        try sandbox.write("earlier", to: sandbox.backup)
        // No file.
        loadedStore().resetAll()
        #expect(try sandbox.read(sandbox.backup) == "earlier")
        // An empty object, however it is spelled.
        for text in ["{ }", "{}\n", "  \n"] {
            try sandbox.write(text)
            loadedStore().resetAll()
            #expect(try sandbox.read(sandbox.backup) == "earlier")
            #expect(try Data(contentsOf: sandbox.config) == empty)
        }
    }

    @Test func noFileMeansNoBackup() throws {
        try ConfigFile(url: sandbox.config).replace(with: empty, keepingBackup: true)
        #expect(!sandbox.exists(sandbox.backup))
        #expect(try Data(contentsOf: sandbox.config) == empty)
    }

    @Test func aBackupThatCannotBeWrittenLeavesTheFileAlone() throws {
        let previous = #"{"dpi": 800}"#
        try sandbox.write(previous)
        // A directory where the backup goes: it cannot be replaced by a file.
        try FileManager.default.createDirectory(at: sandbox.backup.appending(path: "occupied"),
                                                withIntermediateDirectories: true)
        #expect(throws: ConfigFile.SaveError.self) {
            try ConfigFile(url: sandbox.config).replace(with: empty, keepingBackup: true)
        }
        #expect(try sandbox.read() == previous)

        let store = loadedStore()
        store.resetAll()
        #expect(try sandbox.read() == previous)
        #expect(store.config.int(["dpi"]) == 800)
        #expect(store.writeError?.contains("wasn't saved") == true)
    }

    @Test func openConfigCreatesAMissingFileWithoutTouchingEdits() throws {
        let clock = ManualClock()
        let store = loadedStore(clock: clock.clock)
        store.set(1200, at: ["dpi"], debounce: true)
        store.createIfMissing()
        #expect(try Data(contentsOf: sandbox.config) == empty)
        #expect(!sandbox.exists(sandbox.backup))
        #expect(store.hasPendingChanges)
        #expect(store.config.int(["dpi"]) == 1200)
        clock.advance(ConfigStore.debounce)
        #expect(try sandbox.tree().int(["dpi"]) == 1200)
    }

    @Test func openConfigLeavesAnExistingFileAlone() throws {
        let text = #"{"dpi": 800}"#
        try sandbox.write(text)
        let store = loadedStore()
        store.createIfMissing()
        #expect(try sandbox.read() == text)
        #expect(!sandbox.exists(sandbox.backup))
        #expect(try ConfigFile(url: sandbox.config).createIfMissing() == nil)
    }

    @Test func aSymlinkedConfigKeepsItsLinkAndBacksUpBesideTheTarget() throws {
        let dotfiles = sandbox.directory.appending(path: "dotfiles", directoryHint: .isDirectory)
        let target = dotfiles.appending(path: "puremouse.json")
        try sandbox.write(#"{"dpi": 800}"#, to: target)
        try FileManager.default.createSymbolicLink(at: sandbox.config, withDestinationURL: target)

        let file = ConfigFile(url: sandbox.config)
        #expect(file.backupURL.path == dotfiles.appending(path: "puremouse.json.bak").resolvingSymlinksInPath().path)
        loadedStore().resetAll()
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.config.path)
        #expect(link == target.path)
        #expect(try Data(contentsOf: target) == empty)
        #expect(try sandbox.read(file.backupURL) == #"{"dpi": 800}"#)
        #expect(!sandbox.exists(sandbox.backup))
    }
}
