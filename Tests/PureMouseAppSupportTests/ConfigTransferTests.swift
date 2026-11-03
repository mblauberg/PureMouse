import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

/// Export Settings… and Import Settings…: a saved file is a valid config; a file that fails is refused
/// naming the field and leaves the config untouched; a confirmed import keeps the previous file as
/// `config.json.bak`; and an import touches nothing but the config file.
@MainActor
struct ConfigTransferTests {
    let sandbox: Sandbox

    init() throws { sandbox = try Sandbox() }

    func loadedStore() -> ConfigStore {
        let store = ConfigStore(locations: sandbox.locations, clock: ManualClock().clock)
        store.reloadConfig()
        return store
    }

    func outside(_ name: String, _ text: String) throws -> URL {
        let url = sandbox.directory.appending(path: "elsewhere", directoryHint: .isDirectory).appending(path: name)
        try sandbox.write(text, to: url)
        return url
    }

    // MARK: Export

    @Test func exportWritesAValidCopyOfTheConfig() throws {
        let text = "{\n  \"dpi\" : 1600,   \"future\": {\"x\": 1.50}\n}\n"
        try sandbox.write(text)
        let target = sandbox.directory.appending(path: "copy.json")
        #expect(loadedStore().exportSettings(to: target) == nil)
        #expect(try sandbox.read(target) == text)
        try ConfigCheck.validate(Data(contentsOf: target))
        // The config itself is as it was.
        #expect(try sandbox.read() == text)
        #expect(!sandbox.exists(sandbox.backup))
    }

    @Test func exportWithNoFileWritesTheEmptyConfig() throws {
        let target = sandbox.directory.appending(path: "copy.json")
        #expect(loadedStore().exportSettings(to: target) == nil)
        #expect(try Data(contentsOf: target) == ConfigTree().data())
        #expect(!sandbox.exists(sandbox.config))
    }

    @Test func exportSavesWaitingEditsFirstAndRefusesAFileThatDoesNotLoad() throws {
        try sandbox.write(#"{"dpi": 800}"#)
        let store = loadedStore()
        store.set(1200, at: ["dpi"], debounce: true)
        let target = sandbox.directory.appending(path: "copy.json")
        #expect(store.exportSettings(to: target) == nil)
        #expect(try sandbox.tree(target).int(["dpi"]) == 1200)

        try sandbox.write(#"{"dpi": 99999}"#)
        store.reloadConfig()
        let other = sandbox.directory.appending(path: "other.json")
        let problem = try #require(store.exportSettings(to: other))
        #expect(problem.contains("dpi"))
        #expect(!sandbox.exists(other))
    }

    @Test func exportReportsAnUnwritableTarget() throws {
        try sandbox.write("{}")
        let problem = loadedStore().exportSettings(to: sandbox.directory.appending(path: "missing/dir/copy.json"))
        #expect(problem?.contains("copy.json") == true)
    }

    // MARK: Import

    @Test func anInvalidFileIsRefusedNamingTheFieldAndNothingChanges() throws {
        let previous = #"{"dpi": 1600}"#
        try sandbox.write(previous)
        let store = loadedStore()
        let file = try outside("bad.json", #"{"apps": {"com.valvesoftware.dota2": {"enabled": "no"}}}"#)
        do {
            _ = try ConfigTransfer.read(file)
            Issue.record("accepted an invalid file")
        } catch {
            #expect((error as? ConfigTransfer.Refusal)?.message == "apps.com.valvesoftware.dota2.enabled: expected true or false")
        }
        #expect(try sandbox.read() == previous)
        #expect(!sandbox.exists(sandbox.backup))
        #expect(store.config.int(["dpi"]) == 1600)

        let notJSON = try outside("notes.json", "hello")
        #expect(throws: ConfigTransfer.Refusal.self) { try ConfigTransfer.read(notJSON) }
        let array = try outside("array.json", "[1, 2]")
        #expect(throws: ConfigTransfer.Refusal.self) { try ConfigTransfer.read(array) }
        let missing = sandbox.directory.appending(path: "nothing.json")
        do {
            _ = try ConfigTransfer.read(missing)
            Issue.record("read a missing file")
        } catch {
            #expect((error as? ConfigTransfer.Refusal)?.message == "PureMouse can't read nothing.json.")
        }
        #expect(try sandbox.read() == previous)
    }

    @Test func aConfirmedImportKeepsThePreviousFileAndWritesTheNewOneUnderTheLock() throws {
        let previous = "{\n  \"dpi\" : 1600\n}\n"
        try sandbox.write(previous)
        let store = loadedStore()
        let incoming = #"{"dpi": 800, "future": {"keep": true}, "apps": {"a.b": {"enabled": false}}}"#
        let file = try outside("in.json", incoming)
        let candidate = try ConfigTransfer.read(file)
        #expect(candidate.data == Data(incoming.utf8))

        #expect(store.importSettings(candidate) == nil)
        #expect(try sandbox.read(sandbox.backup) == previous)
        #expect(try sandbox.read() == incoming)
        #expect(store.config.int(["dpi"]) == 800)
        #expect(!store.config.isAppEnabled("A.B"))
        #expect(store.configError == nil)
        #expect(FileManager.default.fileExists(atPath: FileLock.url(for: sandbox.config).path))
    }

    @Test func importReplacesAFileThatDoesNotLoad() throws {
        let broken = #"{"dpi": 800,"#
        try sandbox.write(broken)
        let store = loadedStore()
        #expect(store.readOnly)
        let file = try outside("good.json", #"{"dpi": 1000}"#)
        #expect(store.importSettings(try ConfigTransfer.read(file)) == nil)
        #expect(try sandbox.read(sandbox.backup) == broken)
        #expect(!store.readOnly)
        #expect(try sandbox.tree().int(["dpi"]) == 1000)
    }

    @Test func importAsksNothingOfTheDaemonOrAnyDevice() throws {
        try sandbox.write(#"{"dpi": 1600}"#)
        let store = loadedStore()
        let before = try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path).filter { $0 != "elsewhere" }
        let file = try outside("in.json", #"{"dpi": 800}"#)
        #expect(store.importSettings(try ConfigTransfer.read(file)) == nil)
        let after = try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path).filter { $0 != "elsewhere" }
        // Only the config, its backup and its lock; nothing in the companion directory (no control
        // request, no status), where every message to the daemon goes.
        #expect(Set(after).subtracting(before) == ["config.json.bak", "config.json.lock"])
        #expect(!sandbox.exists(sandbox.locations.companion))
        #expect(sandbox.control() == nil)
    }

    // MARK: The confirmation

    @Test func theConfirmationNamesRunCommandsWhenTheFileHasThem() throws {
        let plain = try outside("plain.json", #"{"buttons": {"back": {"keys": "cmd+w"}}}"#)
        let text = ConfigTransfer.confirmation(for: try ConfigTransfer.read(plain), backupName: "config.json.bak")
        #expect(text.title == "Replace all settings?")
        #expect(text.message.contains("config.json.bak"))
        #expect(!text.message.contains("runs commands"))

        let running = try outside("run.json", """
            {"buttons": {"back": {"run": "open -a Safari"}, "top": {"keys": "cmd+t", "run": "ignored"}},
             "thumbWheel": {"left": {"run": "echo l"}},
             "apps": {"a.b": {"buttons": {"forward": {"run": "echo f"}}}},
             "devices": {"mb": {"buttons": {"middle": {"run": "echo d"}}}}}
            """)
        let candidate = try ConfigTransfer.read(running)
        #expect(candidate.runCommands == 4)
        #expect(ConfigTransfer.confirmation(for: candidate, backupName: "config.json.bak").message
            .hasSuffix("This file runs commands: 4"))
    }
}
