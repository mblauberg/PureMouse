import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport
@testable import PureMouseSettingsUI

/// General's device rows and the About This Mouse sheet: which mice are listed, and that the sheet
/// is read-only, built on the shared sheet, and named for the mouse.
@Suite struct DeviceRowsTests {
    private static let ui = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: ui.appending(path: name), encoding: .utf8)
    }

    private static func mouse(_ id: String, _ name: String) -> Status.Device {
        Status.Device(id: id, name: name, connection: .receiver, online: true, battery: nil, dpi: nil,
                      dpiSteps: [], wheelMode: nil, controls: [], model: "mb03400000000")
    }

    @Test func oneRowForOneMouseTwoForTwoNoneForAFreshInstall() {
        let one = [Self.mouse("1-1", "MX Master 3S")]
        let two = one + [Self.mouse("2-1", "M750")]
        #expect(DeviceRow.shown(one, daemonRunning: true).count == 1)
        #expect(DeviceRow.shown(two, daemonRunning: true).map(\.name) == ["MX Master 3S", "M750"])
        #expect(DeviceRow.shown([], daemonRunning: true).isEmpty)
        // A status file outlives the daemon: with PureMouse off no mouse is listed.
        #expect(DeviceRow.shown(two, daemonRunning: false).isEmpty)
    }

    @Test func generalListsThemInStatusBeforeTheNotices() throws {
        let general = try Self.source("GeneralPane.swift")
        let running = try #require(general.range(of: "runningRow\n"))
        let rows = try #require(general.range(of: "DeviceRow(device: device"))
        let notices = try #require(general.range(of: "ForEach(notices"))
        #expect(running.lowerBound < rows.lowerBound && rows.lowerBound < notices.lowerBound)
        #expect(general.contains("settings?.refit()"))
        #expect(general.contains("devices.map(\\.id)"))
    }

    @Test func theInfoButtonIsNamedForTheMouseAndMeetsTheTargetSize() throws {
        let rows = try Self.source("DeviceRows.swift")
        #expect(rows.contains(".accessibilityLabel(device.name)"))
        #expect(rows.contains("Image(systemName: \"info.circle\").padding(4)"))
        #expect(!rows.contains(".frame("))
    }

    @Test func theSheetIsTheSharedSheetWithDoneAndCopyDetailsOnly() throws {
        let rows = try Self.source("DeviceRows.swift")
        #expect(rows.contains("AdvancedSheet(title: device.name)"))
        #expect(rows.contains("Button(\"Copy Details\")"))
        #expect(rows.contains("NSPasteboard.general.setString(details.copyText, forType: .string)"))
        // Done is the shared sheet's; no Switch, no pairing, no setters, no second sheet.
        #expect(rows.components(separatedBy: "Button").count == 3, "the info button and Copy Details")
        #expect(!rows.contains("Switch"))
        #expect(!rows.contains(".sheet(") || rows.components(separatedBy: ".sheet(").count == 2)
        let sheet = try #require(rows.range(of: "struct AboutMouseSheet").map { String(rows[$0.lowerBound...]) })
        #expect(!sheet.contains(".sheet("))
        #expect(!sheet.contains("model.update") && !sheet.contains("model.set("))
    }

    @Test func theDevHookOpensTheSheetForTheFirstMouse() throws {
        let hooks = try Self.source("DevHooks.swift")
        #expect(hooks.contains("case aboutMouse"))
        let general = try Self.source("GeneralPane.swift")
        #expect(general.contains("index == 0 && DevHooks.sheet(on: \"general\") == .aboutMouse"))
    }
}
