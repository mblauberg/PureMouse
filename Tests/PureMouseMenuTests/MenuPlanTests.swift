import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseMenu

/// Golden rows for the status menu: titles, order, checkmarks, attention rows, key equivalents,
/// alternates and what each row does, per state. VoiceOver reads a header as its title and lines
/// joined with ", ", which the header rows below spell out.
struct MenuPlanTests {
    /// One line per row; a submenu's rows are indented under it.
    func dump(_ rows: [MenuRow], indent: String = "") -> String {
        rows.map { row -> String in
            switch row {
            case .separator:
                return indent + "---"
            case let .header(title, lines, alternate):
                return indent + (alternate ? "⌥header " : "header ") + ([title] + lines).joined(separator: ", ")
            case let .item(item):
                var tags: [String] = []
                if !item.key.isEmpty { tags.append("⌘" + item.key) }
                if item.checked { tags.append("on") }
                if item.attention { tags.append("attention") }
                if !item.enabled { tags.append("disabled") }
                if item.alternate { tags.append("alternate") }
                if let action = item.action { tags.append("-> \(action)") }
                var line = indent + item.title + (tags.isEmpty ? "" : " [" + tags.joined(separator: ", ") + "]")
                if let submenu = item.submenu { line += "\n" + dump(submenu, indent: indent + "  ") }
                return line
            }
        }.joined(separator: "\n")
    }

    func lines(_ state: MenuState, option: Bool = false) -> String {
        dump(MenuPlan.rows(for: state, option: option))
    }

    static let footer = """
        ---
        Settings… [⌘,, -> openSettings(nil)]
        Quit PureMouse [⌘q, -> quit]
        Hide Menu Bar Icon [alternate, -> hideMenuBarIcon]
        """

    static func mouse(_ id: String, name: String = "MX Master 3S", connection: Status.Device.Connection = .receiver,
                      online: Bool = true, percent: Int? = 80, dpi: Int? = 800, steps: [Int] = [400, 800, 1600],
                      wheel: Status.Device.WheelMode? = .ratchet) -> Status.Device {
        Status.Device(id: id, name: name, connection: connection, online: online,
                      battery: percent.map { .init(percent: $0, level: .good, charging: false) }, dpi: dpi,
                      dpiSteps: steps, wheelMode: wheel, controls: [])
    }

    static func running(_ devices: [Status.Device] = [mouse("a")]) -> MenuState {
        MenuState(daemonRunning: true, version: "0.3.0", devices: devices, dpiPresets: [400, 800],
                  currentDPI: devices.first?.dpi, dpiSteps: devices.first?.dpiSteps ?? [])
    }

    @Test func daemonNotRunning() {
        let state = MenuState(dpiPresets: [400, 800], currentDPI: 800)
        #expect(lines(state) == """
            header PureMouse Is Off, The mouse works as it does without PureMouse
            ---
            Smooth Scrolling [on, disabled, -> toggleSmoothScrolling]
            Pointer Speed [disabled]
              400 DPI [-> setDPI(400)]
              800 DPI [on, -> setDPI(800)]
              ---
              Edit Presets… [-> openSettings(Optional(PureMouseAppSupport.SettingsPane.pointer))]
            ---
            Start PureMouse [-> start]
            \(Self.footer)
            """)
        // ⌥ adds nothing while the daemon is off.
        #expect(lines(state, option: true) == lines(state))
    }

    @Test func aNewerDaemonAsksForAnUpdateEvenWhenOff() {
        var state = MenuState()
        state.statusTooNew = true
        #expect(lines(state).hasPrefix("""
            header PureMouse Is Off, The mouse works as it does without PureMouse
            Update PureMouse… [attention, -> openReleases]
            ---
            """))
    }

    @Test func oneMouse() {
        #expect(lines(Self.running()) == """
            header MX Master 3S, USB receiver · Battery 80%
            ⌥header MX Master 3S, USB receiver · Battery 80%, 800 DPI · Wheel: ratchet · v0.3.0
            ---
            Smooth Scrolling [on, -> toggleSmoothScrolling]
            Pointer Speed
              400 DPI [-> setDPI(400)]
              800 DPI [on, -> setDPI(800)]
              ---
              Edit Presets… [-> openSettings(Optional(PureMouseAppSupport.SettingsPane.pointer))]
            ---
            Pause PureMouse [-> setPaused(true)]
            \(Self.footer)
            """)
    }

    /// Hide Menu Bar Icon is always there as Quit's alternate (AppKit shows it while ⌥ is held,
    /// also when ⌥ is pressed after the menu opens); Reload Config and Show Log only when ⌥ was
    /// held as it opened.
    @Test func optionAddsReloadAndShowLog() {
        #expect(!lines(Self.running()).contains("Reload Config"))
        #expect(!lines(Self.running()).contains("Show Log"))
        #expect(lines(Self.running()).hasSuffix(Self.footer))
        #expect(lines(Self.running(), option: true).hasSuffix(Self.footer))
        #expect(lines(Self.running(), option: true).contains("""
            Pause PureMouse [-> setPaused(true)]
            Reload Config [-> reloadConfig]
            Show Log in Finder [-> showLog]
            ---
            Settings…
            """))
    }

    @Test func twoMiceEachGetAHeader() {
        let state = Self.running([
            Self.mouse("a"),
            Self.mouse("b", name: "MX Anywhere 3", connection: .bluetooth, online: false, dpi: nil, wheel: .freespin),
        ])
        #expect(lines(state).hasPrefix("""
            header MX Master 3S, USB receiver · Battery 80%
            ⌥header MX Master 3S, USB receiver · Battery 80%, 800 DPI · Wheel: ratchet · v0.3.0
            header MX Anywhere 3, Asleep
            ⌥header MX Anywhere 3, Asleep, Wheel: free spin · v0.3.0
            ---
            """))
    }

    @Test func noMouseConnected() {
        var state = Self.running([])
        state.currentDPI = nil
        #expect(lines(state) == """
            header No Mouse Connected, Turn on your mouse or check the receiver
            ---
            Smooth Scrolling [on, -> toggleSmoothScrolling]
            Pointer Speed
              400 DPI [-> setDPI(400)]
              800 DPI [-> setDPI(800)]
              ---
              Edit Presets… [-> openSettings(Optional(PureMouseAppSupport.SettingsPane.pointer))]
            ---
            Pause PureMouse [-> setPaused(true)]
            \(Self.footer)
            """)
    }

    @Test func pausedDropsTheMice() {
        var state = Self.running([])
        state.paused = true
        let text = lines(state)
        #expect(text.hasPrefix("header PureMouse Is Paused, The mouse works as it does without PureMouse\n---"))
        #expect(text.contains("Resume PureMouse [-> setPaused(false)]"))
    }

    @Test func pausedOrAwayPrefixesTheSubtitle() {
        var state = Self.running()
        state.paused = true
        #expect(lines(state).hasPrefix("header MX Master 3S, Paused · USB receiver · Battery 80%\n"))
        state.paused = false
        state.away = true
        #expect(lines(state).hasPrefix("header MX Master 3S, On another Mac · USB receiver · Battery 80%\n"))
    }

    /// The spoken label names the same state as the header, paused before away.
    @Test func theSpokenLabelSaysPausedBeforeAway() {
        var state = Self.running()
        state.away = true
        let mouse = state.devices.first
        #expect(StatusText.accessibilityLabel(state, primary: mouse) == "PureMouse, MX Master 3S, battery 80 percent, on another Mac")
        state.paused = true
        #expect(StatusText.accessibilityLabel(state, primary: mouse) == "PureMouse, MX Master 3S, battery 80 percent, paused")
    }

    /// The status item badges exactly when the menu shows an attention row.
    @Test func theBadgeFollowsTheAttentionRows() {
        var off = MenuState()
        off.accessibilityMissing = true
        #expect(!off.needsAttention)
        off.statusTooNew = true
        #expect(off.needsAttention)
        var state = Self.running()
        state.inputMonitoringMissing = true
        #expect(!state.needsAttention)
        state.hasBluetoothDevice = true
        #expect(state.needsAttention)
        #expect(StatusText.accessibilityLabel(state, primary: state.devices.first).hasSuffix(", needs attention"))
    }

    @Test func everyAttentionRowInOrder() {
        var state = Self.running()
        state.statusTooNew = true
        state.accessibilityMissing = true
        state.inputMonitoringMissing = true
        state.hasBluetoothDevice = true
        state.configError = true
        state.logiOptionsRunning = true
        #expect(lines(state).contains("""
            v0.3.0
            Update PureMouse… [attention, -> openReleases]
            Allow Accessibility Access… [attention, -> openPrivacy(PureMouseAppSupport.PrivacyPane.accessibility)]
            Allow Input Monitoring… [attention, -> openPrivacy(PureMouseAppSupport.PrivacyPane.inputMonitoring)]
            Fix Config File… [attention, -> openSettings(Optional(PureMouseAppSupport.SettingsPane.general))]
            Logi Options+ Is Running… [attention, -> openSettings(Optional(PureMouseAppSupport.SettingsPane.general))]
            ---
            """))
    }

    /// macOS reserves ⌥⌘Q for "Quit and Keep Windows", so the alternate has no key equivalent.
    @Test func hideMenuBarIconHasNoKeyEquivalent() throws {
        let rows = MenuPlan.rows(for: Self.running(), option: false)
        let hide = try #require(rows.compactMap { row -> MenuItem? in
            if case let .item(item) = row, item.title == "Hide Menu Bar Icon" { return item }
            return nil
        }.first)
        #expect(hide.alternate)
        #expect(hide.key.isEmpty)
    }

    @Test func theSpokenHeaderReadsNoSeparatorDot() {
        let spoken = MenuPlan.spokenHeader(title: "MX Master 3S", lines: ["USB receiver · Battery 45%", "800 DPI · v0.3.0"])
        #expect(spoken == "MX Master 3S, USB receiver, Battery 45%, 800 DPI, v0.3.0")
        #expect(!spoken.contains("·"))
        let paused = MenuPlan.spokenHeader(title: "MX Master 3S", lines: ["Paused · USB receiver · Battery 45%"])
        #expect(paused == "MX Master 3S, Paused, USB receiver, Battery 45%")
    }

    @Test func inputMonitoringMattersOnlyWithABluetoothMouse() {
        var state = Self.running()
        state.inputMonitoringMissing = true
        #expect(!lines(state).contains("Input Monitoring"))
    }

    @Test func aConfigErrorMakesTheConfigRowsReadOnly() {
        var state = Self.running()
        state.configError = true
        state.readOnly = true
        let text = lines(state)
        #expect(text.contains("Smooth Scrolling [on, disabled, -> toggleSmoothScrolling]"))
        #expect(text.contains("  400 DPI [disabled, -> setDPI(400)]"))
        #expect(text.contains("  Edit Presets… [-> openSettings"))
    }

    @Test func pointerSpeedOffThePresets() {
        var state = Self.running([Self.mouse("a", dpi: 1600)])
        state.smoothScrolling = false
        #expect(lines(state).contains("""
            Smooth Scrolling [-> toggleSmoothScrolling]
            Pointer Speed
              400 DPI [-> setDPI(400)]
              800 DPI [-> setDPI(800)]
              Custom: \(Format.dpi(1600)) [on, disabled]
              ---
            """))
        state.dpiPresets = []
        #expect(lines(state).contains("""
            Pointer Speed
              \(Format.dpi(1600)) [on, disabled]
              ---
              Add Presets… [-> openSettings(Optional(PureMouseAppSupport.SettingsPane.pointer))]
            """))
        state.currentDPI = nil
        #expect(lines(state).contains("""
            Pointer Speed
              Add Presets… [-> openSettings
            """))
    }

    @Test func aPresetOffTheSensorListIsCheckedAtItsStep() {
        var state = Self.running([Self.mouse("a", dpi: 800, steps: [400, 800, 1600])])
        state.dpiPresets = [750]
        #expect(lines(state).contains("  750 DPI [on, -> setDPI(750)]"))
    }
}
