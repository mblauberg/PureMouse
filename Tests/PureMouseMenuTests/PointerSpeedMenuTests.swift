import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseMenu

/// Pointer Speed with two mice (#55): a section per mouse, where a choice is written, and what
/// VoiceOver reads.
@MainActor
struct PointerSpeedMenuTests {
    static let masterKey = "mb03400000000"
    static let anywhereKey = "mb03300000000"

    static func mouse(_ name: String, key: String?, dpi: Int? = 800, online: Bool = true, id: String? = nil) -> Status.Device {
        Status.Device(id: id ?? name, name: name, connection: .receiver, online: online, battery: nil, dpi: dpi,
                      dpiSteps: [400, 800, 1600, 3200], wheelMode: nil, controls: [], model: key)
    }

    static let master = mouse("MX Master 3S", key: masterKey, dpi: 1600)
    static let anywhere = mouse("MX Anywhere 3S", key: anywhereKey, dpi: 1000)

    static func state(_ devices: [Status.Device], top: [Int] = [400, 800, 1600],
                      presets: [String: [Int]] = [:], scoped: Set<String> = []) -> MenuState {
        MenuState(daemonRunning: true, devices: devices, dpiPresets: top, mousePresets: presets, dpiScoped: scoped,
                  currentDPI: devices.first?.dpi, dpiSteps: devices.first?.dpiSteps ?? [])
    }

    static func pointerItem(_ state: MenuState) throws -> MenuItem {
        for case let .item(item) in MenuPlan.rows(for: state, option: false) where item.title == "Pointer Speed" { return item }
        throw Failure()
    }

    struct Failure: Error {}

    func dump(_ state: MenuState) throws -> String {
        MenuPlanTests().dump(try #require(Self.pointerItem(state).submenu))
    }

    // MARK: Rows

    @Test func twoMiceShowASectionEachWithTheirOwnPresetsAndOneEditRow() throws {
        let state = Self.state([Self.master, Self.anywhere],
                               presets: [Self.masterKey: [800, 1600, 3200], Self.anywhereKey: [400, 800]])
        #expect(try dump(state) == """
            section MX Master 3S
            \(Format.dpi(800)) [-> setDeviceDPI(800, device: "\(Self.masterKey)")]
            \(Format.dpi(1600)) [on, -> setDeviceDPI(1600, device: "\(Self.masterKey)")]
            \(Format.dpi(3200)) [-> setDeviceDPI(3200, device: "\(Self.masterKey)")]
            section MX Anywhere 3S
            \(Format.dpi(400)) [-> setDeviceDPI(400, device: "\(Self.anywhereKey)")]
            \(Format.dpi(800)) [-> setDeviceDPI(800, device: "\(Self.anywhereKey)")]
            Custom: \(Format.dpi(1000)) [on, disabled]
            ---
            Edit Presets… [-> editPresets]
            """)
    }

    @Test func eachMouseIsCheckedAgainstItsOwnDPI() throws {
        let state = Self.state([Self.master, Self.anywhere], presets: [Self.masterKey: [800, 1600], Self.anywhereKey: [800, 1600]])
        let rows = try #require(Self.pointerItem(state).submenu)
        let checked = rows.compactMap { row -> String? in
            if case let .item(item) = row, item.checked { return item.title }
            return nil
        }
        // 1,600 on the first mouse; the second is on 1,000, off its presets.
        #expect(checked == [Format.dpi(1600), "Custom: \(Format.dpi(1000))"])
    }

    @Test func aMouseWithNoPresetsListsOnlyItsCurrentSpeed() throws {
        let state = Self.state([Self.master, Self.anywhere], top: [], presets: [Self.masterKey: [], Self.anywhereKey: []])
        #expect(try dump(state) == """
            section MX Master 3S
            \(Format.dpi(1600)) [on, disabled]
            section MX Anywhere 3S
            \(Format.dpi(1000)) [on, disabled]
            ---
            Add Presets… [-> editPresets]
            """)
    }

    @Test func miceOfOneModelAreOneSectionAndAsleepMiceAreLeftOut() throws {
        let twin = Self.mouse("MX Master 3S", key: Self.masterKey, dpi: 800, id: "twin")
        let asleep = Self.mouse("MX Anywhere 3S", key: Self.anywhereKey, online: false)
        // One online model: the rows as for one mouse, with no section.
        let one = Self.state([Self.master, twin, asleep], presets: [Self.masterKey: [400, 800, 1600]])
        let rows = try dump(one)
        #expect(!rows.contains("section"))
        #expect(rows.contains("-> setDPI(800)"))
        // A second model online makes two sections.
        let two = Self.state([Self.master, twin, Self.anywhere])
        #expect(try dump(two).components(separatedBy: "section ").count == 3)
    }

    @Test func aMouseWithNoKeyIsASectionThatWritesTheTopLevel() throws {
        let keyless = Self.mouse("Old Mouse", key: nil, dpi: 800)
        let state = Self.state([Self.master, keyless], presets: [Self.masterKey: [1600]])
        let text = try dump(state)
        #expect(text.contains("section Old Mouse"))
        #expect(text.contains("\(Format.dpi(800)) [on, -> setDPI(800)]"))
        #expect(text.contains("\(Format.dpi(1600)) [on, -> setDeviceDPI(1600, device: \"\(Self.masterKey)\")]"))
    }

    // MARK: One mouse

    @Test func oneMouseWritesTheTopLevelUnlessItsOwnEntrySetsTheSpeed() throws {
        let flat = Self.state([Self.master])
        #expect(try dump(flat).contains("-> setDPI(400)"))
        #expect(!(try dump(flat)).contains("setDeviceDPI"))
        let scoped = Self.state([Self.master], presets: [Self.masterKey: [400, 800, 1600]], scoped: [Self.masterKey])
        #expect(try dump(scoped).contains("-> setDeviceDPI(400, device: \"\(Self.masterKey)\")"))
        // Another mouse's entry does not move this one.
        let other = Self.state([Self.master], scoped: [Self.anywhereKey])
        #expect(!(try dump(other)).contains("setDeviceDPI"))
    }

    @Test func oneMouseShowsItsOwnPresetsWhenItsEntryHasThem() throws {
        let state = Self.state([Self.master], presets: [Self.masterKey: [3200]], scoped: [Self.masterKey])
        let rows = try dump(state)
        #expect(rows.contains(Format.dpi(3200)) && !rows.contains(Format.dpi(400)))
    }

    // MARK: VoiceOver

    @Test func aPresetUnderASectionIsReadWithTheMouseAndTheStatusItemCountsMice() throws {
        let state = Self.state([Self.master, Self.anywhere], presets: [Self.masterKey: [1600], Self.anywhereKey: [1600]])
        let rows = try #require(Self.pointerItem(state).submenu)
        let spoken = rows.compactMap { row -> String? in
            if case let .item(item) = row { return item.spoken }
            return nil
        }
        #expect(spoken == ["1,600 DPI, MX Master 3S", "1,600 DPI, MX Anywhere 3S", "Custom: 1,000 DPI, MX Anywhere 3S"])
        #expect(StatusText.accessibilityLabel(state, primary: Self.master)
                == "PureMouse, MX Master 3S, 2 mice connected")
        // One mouse: nothing added, and no spoken title on its rows.
        let one = Self.state([Self.master], presets: [Self.masterKey: [1600]])
        #expect(StatusText.accessibilityLabel(one, primary: Self.master) == "PureMouse, MX Master 3S")
        #expect(try #require(Self.pointerItem(one).submenu).allSatisfy { row in
            if case let .item(item) = row { item.spoken == nil } else { true }
        })
    }

    // MARK: Writing

    static func model(config: String, devices: [Status.Device]) throws -> (AppModel, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-\(UUID().uuidString)")
        let companion = directory.appending(path: "companion", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: true)
        let locations = Locations(config: directory.appending(path: "config.json"),
                                  log: directory.appending(path: "PureMouse.log"), daemon: nil, companion: companion)
        try Data(config.utf8).write(to: locations.config)
        var status = Status(pid: getpid(), startedAt: Date(timeIntervalSince1970: 0), version: "0.3.0", running: true,
                            paused: false, permissions: .init(accessibility: true, inputMonitoring: true),
                            logiOptionsRunning: false, config: .init(path: locations.config.path, error: nil),
                            devices: devices, capture: nil)
        status.schema = Status.currentSchema
        try Companion.write(status, to: locations.status)
        let model = AppModel(locations: locations, defaults: UserDefaults(suiteName: "pm-\(UUID().uuidString)")!,
                             alert: { _, _ in })
        model.reloadStatus()
        return (model, locations.config, locations.control)
    }

    static func saved(_ url: URL) throws -> ConfigTree { try ConfigTree(data: Data(contentsOf: url)) }

    @Test func choosingForOneMouseWritesOnlyItsEntryAndAsksOnlyThatMouse() throws {
        let (model, config, control) = try Self.model(config: #"{"dpi": 800}"#, devices: [Self.master, Self.anywhere])
        model.setPointerSpeed(3200, device: Self.anywhereKey)
        model.flush()
        let tree = try Self.saved(config)
        #expect(tree.int(["devices", Self.anywhereKey, "dpi"]) == 3200)
        #expect(tree.string(["devices", Self.anywhereKey, "name"]) == "MX Anywhere 3S")
        #expect(tree.int(["dpi"]) == 800 && !tree.contains(["devices", Self.masterKey]))
        let request = try #require(Companion.read(Control.self, from: control))
        #expect(request.device == Self.anywhereKey && request.useConfiguredDPI != nil)
    }

    @Test func choosingWithNoDeviceWritesTheTopLevelAndAsksEveryMouse() throws {
        let (model, config, control) = try Self.model(config: "{}", devices: [Self.master])
        model.setPointerSpeed(3200, device: nil)
        model.flush()
        let tree = try Self.saved(config)
        #expect(tree.int(["dpi"]) == 3200 && !tree.contains(["devices"]))
        let request = try #require(Companion.read(Control.self, from: control))
        #expect(request.device == nil && request.useConfiguredDPI != nil)
    }

    @Test func aKeyKitWouldNotReadWritesTheTopLevel() throws {
        let (model, config, _) = try Self.model(config: "{}", devices: [Self.master])
        model.setPointerSpeed(3200, device: "not-a-key")
        model.flush()
        let tree = try Self.saved(config)
        #expect(tree.int(["dpi"]) == 3200 && !tree.contains(["devices"]))
    }

    @Test func theStateReadsEachMousesPresetsAndWhichEntriesSetTheSpeed() throws {
        let config = """
            {"dpi": 800, "dpiPresets": [400, 800],
             "devices": {"\(Self.masterKey)": {"name": "MX Master 3S", "dpiPresets": [1600, 3200]}}}
            """
        let (model, _, _) = try Self.model(config: config, devices: [Self.master, Self.anywhere])
        let state = MenuState(model: model)
        #expect(state.mousePresets == [Self.masterKey: [1600, 3200], Self.anywhereKey: [400, 800]])
        #expect(state.dpiScoped == [Self.masterKey])
        #expect(state.dpiPresets == [400, 800])
    }
}
