import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseSettingsUI

// Import Settings… and Export Settings… past the panels: the steps the panels and the dev hooks share,
// and where the buttons sit (General › Advanced…, read from the source).

@MainActor
@Suite struct ConfigTransferActionsTests {
    private let directory: URL
    private let locations: Locations

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        locations = Locations(config: directory.appending(path: "config.json"), log: directory.appending(path: "PureMouse.log"),
                              daemon: nil, companion: directory.appending(path: "companion", directoryHint: .isDirectory))
    }

    private func model(config text: String) throws -> AppModel {
        try Data(text.utf8).write(to: locations.config)
        let model = AppModel(locations: locations, defaults: UserDefaults(suiteName: "pm-\(UUID().uuidString)")!, alert: { _, _ in })
        model.reloadConfig()
        return model
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    @Test func cancelChangesNothing() throws {
        let model = try model(config: #"{"dpi": 1600}"#)
        let incoming = try file("in.json", #"{"dpi": 800}"#)
        var asked: ConfigTransfer.Candidate?
        let outcome = ConfigTransferActions.importSettings(model, from: incoming) { asked = $0; return false }
        #expect(outcome == .cancelled)
        #expect(asked?.runCommands == 0)
        #expect(try text(locations.config) == #"{"dpi": 1600}"#)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "config.json.bak").path))
    }

    @Test func aRefusedFileIsNeverAskedAboutAndLeavesTheConfig() throws {
        let model = try model(config: #"{"dpi": 1600}"#)
        let incoming = try file("in.json", #"{"smoothScroll": {"speed": "fast"}}"#)
        let outcome = ConfigTransferActions.importSettings(model, from: incoming) { _ in
            Issue.record("asked about a file that failed")
            return true
        }
        #expect(outcome == .refused("smoothScroll.speed: expected a number"))
        #expect(try text(locations.config) == #"{"dpi": 1600}"#)
    }

    @Test func confirmedReplacesAndKeepsTheBackup() throws {
        let model = try model(config: #"{"dpi": 1600}"#)
        let incoming = try file("in.json", #"{"dpi": 800}"#)
        #expect(ConfigTransferActions.importSettings(model, from: incoming) { _ in true } == .replaced)
        #expect(try text(locations.config) == #"{"dpi": 800}"#)
        #expect(try text(directory.appending(path: "config.json.bak")) == #"{"dpi": 1600}"#)
        #expect(model.config.int(["dpi"]) == 800)
    }

    #if DEBUG
    @Test func theDevHooksDriveExportAndImportWithAPath() throws {
        let model = try model(config: #"{"dpi": 1600}"#)
        let copy = directory.appending(path: "export.json")
        var said: [String] = []
        #expect(DevTransfer.run(model, environment: ["PUREMOUSE_DEV_EXPORT": copy.path], report: { said.append($0) }))
        #expect(said == ["export: ok"])
        #expect(try text(copy) == #"{"dpi": 1600}"#)

        let incoming = try file("in.json", #"{"dpi": 800}"#)
        said = []
        #expect(DevTransfer.run(model, environment: ["PUREMOUSE_DEV_IMPORT": incoming.path,
                                                     "PUREMOUSE_DEV_IMPORT_CANCEL": "1"], report: { said.append($0) }))
        #expect(said == ["import: cancelled"])
        #expect(try text(locations.config) == #"{"dpi": 1600}"#)

        said = []
        #expect(DevTransfer.run(model, environment: ["PUREMOUSE_DEV_IMPORT": incoming.path], report: { said.append($0) }))
        #expect(said == ["import: replaced"])
        #expect(try text(locations.config) == #"{"dpi": 800}"#)

        let bad = try file("bad.json", #"{"apps": {"a.b": {"enabled": 3}}}"#)
        said = []
        #expect(DevTransfer.run(model, environment: ["PUREMOUSE_DEV_IMPORT": bad.path], report: { said.append($0) }))
        #expect(said == ["import: refused: apps.a.b.enabled: expected true or false"])
        #expect(!DevTransfer.run(model, environment: [:], report: { said.append($0) }))
    }
    #endif

    @Test func generalAdvancedHasBothButtonsAndTheAppPageLeadsWithTheSwitch() throws {
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PureMouseSettingsUI")
        let general = try String(contentsOf: ui.appending(path: "GeneralPane.swift"), encoding: .utf8)
        #expect(general.contains(#"Button("Export Settings…")"#) && general.contains(#"Button("Import Settings…")"#))
        let page = try String(contentsOf: ui.appending(path: "AppPage.swift"), encoding: .utf8)
        let switchRow = try #require(page.range(of: "useSwitch(model.config)"))
        let rest = try #require(page.range(of: "case .buttons: buttons(model.config)"))
        #expect(switchRow.lowerBound < rest.lowerBound, "the switch is the page's first row")
        #expect(page.contains("RowLabel(\"Use PureMouse in this app\""))
        #expect(ConfigTree.useInAppCaption == "Applies your buttons and scrolling here. Turn off for games and remote desktops.")
    }
}
