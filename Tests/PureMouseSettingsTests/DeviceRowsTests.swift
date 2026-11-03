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
        // Every row that comes and goes after the window was sized refits it: the notification row
        // pushed Advanced… out of view when it appeared on a Mac with notifications off.
        #expect(general.contains(".onChange(of: notificationsDenied) { settings?.refit() }"))
    }

    @Test func theInfoButtonIsNamedForTheMouseAndMeetsTheTargetSize() throws {
        let rows = try Self.source("DeviceRows.swift")
        #expect(rows.contains(".accessibilityLabel(\"About \\(device.name)\")"))
        // Padding on the leading and vertical sides only, so the glyph sits at the row's trailing edge.
        #expect(rows.contains("Image(systemName: \"info.circle\").padding(.vertical, 4).padding(.leading, 6)"))
        #expect(!rows.contains(".frame(width: 2") && !rows.contains(".frame(height"))
    }

    @Test func theSheetIsTheSharedSheetWithDoneAndCopyDetailsOnly() throws {
        let rows = try Self.source("DeviceRows.swift")
        #expect(rows.contains("AdvancedSheet(title: device.name)"))
        #expect(rows.contains("Button(\"Copy Details\")"))
        #expect(rows.contains("NSPasteboard.general.setString(details.copyText, forType: .string)"))
        // Done is the shared sheet's; no Switch, no pairing, no setters, no second sheet.
        #expect(rows.components(separatedBy: "Button").count == 4,
                "Apply Settings Again, the info button and Copy Details")
        #expect(!rows.contains("Switch"))
        #expect(!rows.contains(".sheet(") || rows.components(separatedBy: ".sheet(").count == 2)
        let sheet = try #require(rows.range(of: "struct AboutMouseSheet").map { String(rows[$0.lowerBound...]) })
        #expect(!sheet.contains(".sheet("))
        #expect(!sheet.contains("model.update") && !sheet.contains("model.set("))
    }

    @Test func theNotAppliedRowOffersApplyAgainAndTheSheetMarksTheCurrentComputerInAGutter() throws {
        let rows = try Self.source("DeviceRows.swift")
        #expect(rows.contains("Button(\"Apply Settings Again\") { model.applySettingsAgain() }"))
        #expect(rows.contains("exclamationmark.triangle"))
        // Two failed mice give two buttons: the visible title is the same, the spoken names are not.
        #expect(rows.contains(".accessibilityLabel(\"Apply Settings Again to \\(device.name)\")"))
        #expect(rows.contains(".accessibilityLabel(\"About \\(device.name)\")"))
        #expect(rows.contains("Image(systemName: \"checkmark\")") && rows.contains(".opacity(line.current ? 1 : 0)"))
    }

    /// While macOS has the notifications off, the row offers the button in place of the switch: a
    /// switch styled inside LabeledContent reads as a plain toggle, and a disabled toggle row would
    /// disable a button in its label.
    @Test func theNotificationButtonTakesTheSwitchesPlaceWhileMacOSHasThemOff() throws {
        let general = try Self.source("GeneralPane.swift")
        let row = try #require(general.range(of: "private var lowBatteryRow").map { String(general[$0.lowerBound...]) })
        let denied = try #require(row.range(of: "if notificationsDenied {"))
        let otherwise = try #require(row.range(of: "} else {"))
        let branch = row[denied.upperBound..<otherwise.lowerBound]
        #expect(branch.contains("Button(\"Open Notification Settings…\")"))
        #expect(!branch.contains("Toggle("))
        #expect(row[otherwise.upperBound...].contains("Toggle(isOn: isOn)"))
    }

    @Test func theDevHookOpensTheSheetForTheFirstMouse() throws {
        let hooks = try Self.source("DevHooks.swift")
        #expect(hooks.contains("case aboutMouse"))
        let general = try Self.source("GeneralPane.swift")
        #expect(general.contains("index == 0 && DevHooks.sheet(on: \"general\") == .aboutMouse"))
    }
}
