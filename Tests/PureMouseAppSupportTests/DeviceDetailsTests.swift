import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

/// About This Mouse: the rows a mouse's status gives, what is hidden, and the text Copy Details
/// copies.
struct DeviceDetailsTests {
    static func mx3S() -> Status.Device {
        Status.Device(
            id: "1-1", name: "MX Master 3S", connection: .receiver, online: true,
            battery: .init(percent: 80, level: .good, charging: true), dpi: 1000, dpiSteps: [],
            wheelMode: nil, controls: [], model: "mb03400000000", unit: "0a1b2c3d", kind: "mouse",
            applied: .init(state: .applied, at: Date(timeIntervalSince1970: 1_700_000_000)),
            firmware: "RBM 22.01 B0015",
            hosts: .init(current: 0, slots: [.init(name: "Studio", paired: true),
                                             .init(name: "MacBook Air", paired: true),
                                             .init(name: nil, paired: false)]))
    }

    /// Only what the M750 reports: no firmware, no hosts, a battery level without a percentage.
    static func m750() -> Status.Device {
        Status.Device(id: "2-1", name: "M750", connection: .receiver, online: true,
                      battery: .init(percent: nil, level: .good, charging: false), dpi: nil, dpiSteps: [],
                      wheelMode: nil, controls: [], model: "pb02c")
    }

    func rows(_ device: Status.Device) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: DeviceDetails(device).rows.map { ($0.label, $0.lines.map(\.text)) })
    }

    @Test func theMXMaster3SShowsEveryRow() {
        let details = DeviceDetails(Self.mx3S())
        #expect(details.title == "MX Master 3S")
        #expect(details.rows.map(\.label) == ["Battery", "Connection", "Easy-Switch", "Firmware", "Model ID"])
        let rows = rows(Self.mx3S())
        #expect(rows["Battery"] == ["80%, charging"])
        #expect(rows["Connection"] == ["USB receiver"])
        #expect(rows["Easy-Switch"] == ["Computer 1 · This Mac", "Computer 2 · MacBook Air", "Computer 3 · Not paired"])
        #expect(rows["Firmware"] == ["RBM 22.01 B0015"])
        #expect(rows["Model ID"] == ["mb03400000000"])  // the key the config uses, lowercase
        #expect(details.rows[2].lines.map(\.current) == [true, false, false])
    }

    @Test func theM750HidesWhatItDoesNotReport() {
        let details = DeviceDetails(Self.m750())
        #expect(details.rows.map(\.label) == ["Battery", "Connection", "Model ID"])
        #expect(!details.rows.contains { $0.label == "Easy-Switch" || $0.label == "Firmware" })
        #expect(rows(Self.m750())["Battery"] == ["Good"])
        #expect(rows(Self.m750())["Model ID"] == ["pb02c"])
    }

    @Test func aMouseThatReportsNothingStillNamesItsConnection() {
        let bare = Status.Device(id: "x", name: "Mouse", connection: .bluetooth, online: true, battery: nil, dpi: nil,
                                 dpiSteps: [], wheelMode: nil, controls: [])
        #expect(DeviceDetails(bare).rows.map(\.label) == ["Connection"])
        #expect(rows(bare)["Connection"] == ["Bluetooth"])
    }

    @Test func aHostTheMouseNamesButDoesNotCallPairedIsStillNamed() {
        var device = Self.mx3S()
        device.hosts = .init(current: 2, slots: [.init(name: "Studio"), .init(), .init()])
        #expect(rows(device)["Easy-Switch"] == ["Computer 1 · Studio", "Computer 2", "Computer 3 · This Mac"])
    }

    @Test func copyDetailsIsPlainTextWithoutTheUnitOrSerial() {
        let device = Self.mx3S()
        let text = DeviceDetails(device, version: "0.5.0").copyText
        #expect(text == """
            MX Master 3S
            Battery: 80%, charging
            Connection: USB receiver
            Easy-Switch:
              Computer 1 · This Mac
              Computer 2 · MacBook Air
              Computer 3 · Not paired
            Firmware: RBM 22.01 B0015
            Model ID: mb03400000000
            PureMouse: 0.5.0
            """)
        #expect(!text.contains(device.unit ?? "unit") && !text.lowercased().contains("serial"))
        // The model ID is shared by every mouse of the model; only the unit names one mouse.
    }

    @Test func aDevBuildSaysSo() {
        #expect(DeviceDetails(Self.m750(), version: "dev").copyText.hasSuffix("PureMouse: dev build"))
    }

    @Test func theStatusRowAddsTheCurrentComputerOnlyWhereReported() {
        #expect(StatusText.row(Self.mx3S()) == "USB receiver · Battery 80%".replacing("Battery 80%", with: "Charging 80%") + " · Computer 1")
        #expect(StatusText.row(Self.m750()) == "USB receiver · Battery good")
        var asleep = Self.mx3S()
        asleep.online = false
        asleep.applied = .init(state: .applied)
        #expect(StatusText.row(asleep) == "Asleep")
        var failed = Self.mx3S()
        failed.online = false
        failed.applied = .init(state: .notApplied)
        #expect(StatusText.row(failed) == "Settings not applied · USB receiver")
        #expect(StatusText.subtitle(failed) == "Settings not applied")  // the menu's header keeps it short
    }

    @Test func theSubtitleSpeaksTheAppliedStatesAndNothingElse() {
        var device = Self.mx3S()
        device.applied = .init(state: .applying)
        #expect(StatusText.subtitle(device) == "Applying settings…")
        device.applied = .init(state: .notApplied)
        #expect(StatusText.subtitle(device) == "Settings not applied")
        device.applied = .init(state: .applied, at: Date())
        #expect(StatusText.subtitle(device) == "USB receiver · Charging 80%")
        device.applied = nil
        #expect(StatusText.subtitle(device) == "USB receiver · Charging 80%")
    }

    @Test func theDetailLineGivesTheTimeOfTheApply() {
        let utc = TimeZone(identifier: "UTC")!
        var device = Self.mx3S()  // applied 2023-11-14 22:13:20 UTC
        device.dpi = nil
        #expect(StatusText.detail(device, version: "0.5.0", locale: Locale(identifier: "en_GB"), timeZone: utc)
                == "Settings applied at 22:13 · v0.5.0")
        var applying = device
        applying.applied = .init(state: .applying)
        #expect(StatusText.detail(applying, version: "dev") == "dev build")
    }
}
