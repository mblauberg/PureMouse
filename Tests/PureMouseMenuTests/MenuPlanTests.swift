import Foundation
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
        Hide Menu Bar Icon [⌘q, alternate, -> hideMenuBarIcon]
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
              Edit Presets… [-> editPresets]
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
            Update PureMouse [attention, -> openReleases]
            ---
            """))
    }

    @Test func aNewerReleaseShowsUpdateAndSkipRowsWithoutAWarning() throws {
        var state = Self.running()
        state.update = UpdateOffer(version: try #require(UpdateCheck.Version("0.6.0")),
                                   page: try #require(URL(string: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0")))
        #expect(lines(state).contains("""
            v0.3.0
            Update to 0.6.0… [-> installUpdate]
            Skip This Version [-> skipUpdate]
            ---
            Smooth Scrolling
            """))
        // Not a warning: no triangle, no badge on the icon.
        #expect(!state.needsAttention)
        state.update = nil
        #expect(!lines(state).contains("Update to"))
    }

    @Test func whileUpdatingTheRowIsDisabledAndSaysSo() throws {
        var state = Self.running()
        state.update = UpdateOffer(version: try #require(UpdateCheck.Version("0.6.0")), page: try #require(URL(string: "https://example.com/r")))
        state.installing = .installing
        #expect(lines(state).contains("""
            Updating to 0.6.0… [disabled]
            Skip This Version [-> skipUpdate]
            """))
        #expect(!lines(state).contains("installUpdate"))
    }

    @Test func aRefusedUpdateGivesItsReasonTheReleasePageAndAnotherTry() throws {
        var state = Self.running()
        let page = try #require(URL(string: "https://example.com/r"))
        state.update = UpdateOffer(version: try #require(UpdateCheck.Version("0.6.0")), page: page)
        state.installing = .failed(reason: "The download doesn't match its checksum", retry: true)
        #expect(lines(state).contains("""
            The download doesn't match its checksum [disabled]
            Update to 0.6.0… [-> installUpdate]
            View Release [-> openUpdate(https://example.com/r)]
            Skip This Version [-> skipUpdate]
            """))
        // A copy that cannot be replaced is not offered a second try that would end the same way.
        state.installing = .failed(reason: "Can't update: this copy needs an administrator", retry: false)
        #expect(lines(state).contains("""
            Can't update: this copy needs an administrator [disabled]
            View Release [-> openUpdate(https://example.com/r)]
            Skip This Version [-> skipUpdate]
            """))
        #expect(!state.needsAttention)
    }

    @Test func onceTheNewAppIsOnDiskTheUpdateRowsAreGone() {
        var state = Self.running()
        state.update = UpdateOffer(version: UpdateCheck.Version("0.6.0")!, page: URL(string: "https://example.com/r")!)
        state.installing = .installed
        let text = lines(state)
        #expect(!text.contains("Update to") && !text.contains("Skip This Version") && !text.contains("View Release"))
    }

    @Test func theUpdateRowsComeAfterTheWarningsAndLeaveTheStatusFormatRowAlone() throws {
        var state = Self.running()
        state.statusTooNew = true
        state.accessibilityMissing = true
        state.update = UpdateOffer(version: try #require(UpdateCheck.Version("1.0")), page: try #require(URL(string: "https://example.com/r")))
        #expect(lines(state).contains("""
            Update PureMouse [attention, -> openReleases]
            Allow Accessibility Access [attention, -> openPrivacy(PureMouseAppSupport.PrivacyPane.accessibility)]
            Update to 1.0… [-> installUpdate]
            Skip This Version [-> skipUpdate]
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
              Edit Presets… [-> editPresets]
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
              Edit Presets… [-> editPresets]
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

    /// A paused PureMouse lists no mouse, and the label still says it is paused.
    @Test func thePausedLabelDoesNotNeedAMouse() {
        var state = Self.running([])
        state.paused = true
        #expect(StatusText.accessibilityLabel(state, primary: nil) == "PureMouse, no mouse connected, paused")
        state.paused = false
        state.away = true
        #expect(StatusText.accessibilityLabel(state, primary: nil) == "PureMouse, no mouse connected, on another Mac")
        // Off says only that: there is no mouse to describe and nothing paused.
        let off = MenuState(dpiPresets: [], currentDPI: nil)
        #expect(StatusText.accessibilityLabel(off, primary: nil) == "PureMouse, off")
    }

    /// A battery that reports a level but no percentage is spoken when it is low or critical.
    @Test func aLevelOnlyBatteryIsSpokenWhenLow() {
        func label(_ level: Status.Device.Battery.Level) -> String {
            var mouse = Self.mouse("a", percent: nil)
            mouse.battery = .init(percent: nil, level: level, charging: false)
            return StatusText.accessibilityLabel(Self.running([mouse]), primary: mouse)
        }
        #expect(label(.low) == "PureMouse, MX Master 3S, battery low")
        #expect(label(.critical) == "PureMouse, MX Master 3S, battery critical")
        #expect(label(.good) == "PureMouse, MX Master 3S")
        #expect(label(.full) == "PureMouse, MX Master 3S")
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
            Update PureMouse [attention, -> openReleases]
            Allow Accessibility Access [attention, -> openPrivacy(PureMouseAppSupport.PrivacyPane.accessibility)]
            Allow Input Monitoring [attention, -> openPrivacy(PureMouseAppSupport.PrivacyPane.inputMonitoring)]
            Fix Config File… [attention, -> openSettings(Optional(PureMouseAppSupport.SettingsPane.tab(PureMouseAppSupport.SettingsTab.general)))]
            Quit Logi Options+ [attention, -> quitLogiOptions]
            Open Login Items Settings… [-> openLoginItems]
            ---
            """))
    }

    /// AppKit folds an alternate into the item before it only when the key equivalents match, so
    /// Hide Menu Bar Icon shares Quit's Q (shown as ⌥⌘Q while ⌥ is held).
    @Test func hideMenuBarIconSharesQuitsKeyEquivalent() throws {
        let rows = MenuPlan.rows(for: Self.running(), option: false)
        let hide = try #require(rows.compactMap { row -> MenuItem? in
            if case let .item(item) = row, item.title == "Hide Menu Bar Icon" { return item }
            return nil
        }.first)
        #expect(hide.alternate)
        #expect(hide.key == "q")
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

    /// A Bluetooth mouse the daemon has seen but cannot talk to: the menu names it, says what it
    /// waits for and offers Allow Input Monitoring, not the advice to check a receiver.
    @Test func aBluetoothMouseWaitingForInputMonitoringIsNamedAndOffersTheAllow() {
        var state = Self.running([])
        state.inputMonitoringMissing = true
        state.waitingForInputMonitoring = ["MX Anywhere 3S"]
        let text = lines(state)
        #expect(text.hasPrefix("header MX Anywhere 3S, Bluetooth · Waiting for Input Monitoring\n"))
        #expect(text.contains("Allow Input Monitoring [attention, -> openPrivacy(PureMouseAppSupport.PrivacyPane.inputMonitoring)]"))
        #expect(!text.contains("check the receiver") && !text.contains("No Mouse Connected"))
        #expect(state.needsAttention)
        // Without a mouse waiting, nothing asks for it.
        state.waitingForInputMonitoring = []
        #expect(!lines(state).contains("Allow Input Monitoring"))
        #expect(lines(state).contains("No Mouse Connected"))
    }

    @Test func aReceiverMouseNeverAsksForInputMonitoring() {
        var state = Self.running()
        state.inputMonitoringMissing = true
        #expect(!lines(state).contains("Allow Input Monitoring") && !state.needsAttention)
    }

    @Test func aConfigErrorMakesTheConfigRowsReadOnly() {
        var state = Self.running()
        state.configError = true
        state.readOnly = true
        let text = lines(state)
        #expect(text.contains("Smooth Scrolling [on, disabled, -> toggleSmoothScrolling]"))
        #expect(text.contains("  400 DPI [disabled, -> setDPI(400)]"))
        #expect(text.contains("  Edit Presets… [-> editPresets"))
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
              Add Presets… [-> editPresets]
            """))
        state.currentDPI = nil
        #expect(lines(state).contains("""
            Pointer Speed
              Add Presets… [-> editPresets]
            """))
    }

    @Test func aPresetOffTheSensorListIsCheckedAtItsStep() {
        var state = Self.running([Self.mouse("a", dpi: 800, steps: [400, 800, 1600])])
        state.dpiPresets = [750]
        #expect(lines(state).contains("  750 DPI [on, -> setDPI(750)]"))
    }

    /// Start PureMouse starts it now and leaves Open at login as it is: `start`, never `register`.
    @Test func startPureMouseRunsStartNotRegister() throws {
        let start = try #require(MenuPlan.rows(for: MenuState(), option: false).compactMap { row -> MenuAction? in
            if case let .item(item) = row, item.title == "Start PureMouse" { return item.action }
            return nil
        }.first)
        #expect(start.command == .start)
        #expect(MenuAction.setPaused(true).command == nil)
    }

    // MARK: Settings for the app in use

    private func settingsRows(front: FrontmostApp?, running: Bool = true) -> String {
        var state = running ? Self.running() : MenuState()
        state.frontmost = front
        return lines(state).split(separator: "\n").drop { !$0.hasPrefix("Settings…") }.joined(separator: "\n")
    }

    @Test func theFrontmostAppGetsItsOwnRowBelowSettings() {
        #expect(settingsRows(front: FrontmostApp(bundleID: "com.apple.Safari", name: "Safari")) == """
            Settings… [⌘,, -> openSettings(nil)]
            Settings for Safari… [-> openAppSettings("com.apple.Safari")]
            Quit PureMouse [⌘q, -> quit]
            Hide Menu Bar Icon [⌘q, alternate, -> hideMenuBarIcon]
            """)
        // PureMouse off or paused: the buttons are not remapped, but the settings are still editable.
        #expect(settingsRows(front: FrontmostApp(bundleID: "com.apple.Safari", name: "Safari"), running: false)
            .contains("Settings for Safari…"))
    }

    @Test func finderDockPureMouseAndAppsWithoutAnIdentifierGetNoRow() {
        let none = settingsRows(front: nil)
        #expect(none == Self.footer.split(separator: "\n").dropFirst().joined(separator: "\n"))
        for id in ["com.apple.finder", "com.apple.Finder", "com.apple.dock", "io.github.mblauberg.puremouse",
                   "io.github.mblauberg.puremouse.menu", "io.github.mblauberg.puremouse.settings",
                   "io.github.mblauberg.PureMouse.Settings", nil, "", "  "] {
            #expect(settingsRows(front: FrontmostApp(bundleID: id, name: "Whatever")) == none, "\(id ?? "nil")")
        }
        // A lookalike is an app like any other.
        #expect(settingsRows(front: FrontmostApp(bundleID: "io.github.mblauberg.puremouse-tool", name: "Tool"))
            .contains("Settings for Tool…"))
    }

    @Test func anAppWithoutANameIsNamedByItsIdentifier() {
        #expect(FrontmostApp(bundleID: "a.b", name: nil).title == "a.b")
        #expect(FrontmostApp(bundleID: "a.b", name: " ").title == "a.b")
        #expect(FrontmostApp(bundleID: "a.b", name: "Ab").title == "Ab")
    }

    @Test func theRowSendsTheAppsIdentifierAsAnAppRequest() throws {
        var state = Self.running()
        state.frontmost = FrontmostApp(bundleID: "com.apple.Safari", name: "Safari")
        let action = try #require(MenuPlan.rows(for: state, option: false).compactMap { row -> MenuAction? in
            if case let .item(item) = row, item.title == "Settings for Safari…" { return item.action }
            return nil
        }.first)
        guard case .openAppSettings(let id) = action else { Issue.record("not an app request"); return }
        #expect(ShowRequest(app: id).app == "com.apple.Safari")
    }

    // MARK: Applied state

    private static let appliedAt = Date(timeIntervalSince1970: 1_700_000_000)

    static func mouse(applied: Status.Device.Applied?) -> Status.Device {
        var device = mouse("a")
        device.applied = applied
        return device
    }

    @Test func whileAllIsAppliedTheMenuHasTheRowsOfBefore() {
        let before = lines(Self.running())
        let applied = Self.running([Self.mouse(applied: .init(state: .applied, at: Self.appliedAt))])
        let time = StatusText.time(Self.appliedAt)
        // The same rows; the header says nothing of it, and only the ⌥ line gains the time.
        #expect(lines(applied) == before.replacing("800 DPI · Wheel: ratchet · v0.3.0",
                                                  with: "800 DPI · Wheel: ratchet · Settings applied at \(time) · v0.3.0"))
        #expect(lines(applied).contains("header MX Master 3S, USB receiver · Battery 80%\n"))
        #expect(!lines(applied).contains("Apply Settings Again"))
        #expect(!applied.needsAttention)
    }

    @Test func theHeaderSaysApplyingWhileSettingsAreBeingApplied() {
        let state = Self.running([Self.mouse(applied: .init(state: .applying))])
        #expect(lines(state).hasPrefix("""
            header MX Master 3S, Applying settings…
            ⌥header MX Master 3S, Applying settings…, 800 DPI · Wheel: ratchet · v0.3.0
            ---
            """))
        // A state in passing: no row, no badge.
        #expect(!lines(state).contains("Apply Settings Again") && !state.needsAttention)
    }

    @Test func aFailedApplyShowsTheHeaderTheAttentionRowAndTheBadge() {
        let state = Self.running([Self.mouse(applied: .init(state: .notApplied))])
        #expect(lines(state).hasPrefix("""
            header MX Master 3S, Settings not applied
            ⌥header MX Master 3S, Settings not applied, 800 DPI · Wheel: ratchet · v0.3.0
            Apply Settings Again [attention, -> applySettingsAgain]
            ---
            """))
        #expect(state.needsAttention)
        #expect(MenuPlan.spokenHeader(title: "MX Master 3S", lines: ["Settings not applied"]) == "MX Master 3S, Settings not applied")
    }

    @Test func theApplyAgainRowIsOneRowForAnyNumberOfMice() {
        let state = Self.running([Self.mouse(applied: .init(state: .notApplied)),
                                  Self.mouse(applied: .init(state: .notApplied))])
        #expect(lines(state).components(separatedBy: "Apply Settings Again").count == 2)
    }

    @Test func applyAgainSitsAmongTheWarnings() {
        var state = Self.running([Self.mouse(applied: .init(state: .notApplied))])
        state.configError = true
        state.logiOptionsRunning = true
        #expect(lines(state).contains("""
            Fix Config File… [attention, -> openSettings(Optional(PureMouseAppSupport.SettingsPane.tab(PureMouseAppSupport.SettingsTab.general)))]
            Apply Settings Again [attention, -> applySettingsAgain]
            Quit Logi Options+ [attention, -> quitLogiOptions]
            """))
    }
}

// MARK: Off in this app

extension MenuPlanTests {
    private static func offState(_ devices: [Status.Device] = [mouse("a")]) -> MenuState {
        var state = running(devices)
        state.frontmost = FrontmostApp(bundleID: "com.valvesoftware.dota2", name: "Dota 2")
        state.frontmostIsOff = true
        return state
    }

    @Test func theHeaderSaysOffInTheAppWhileTheFrontmostAppIsOff() {
        let text = lines(Self.offState())
        #expect(text.hasPrefix("header MX Master 3S, Off in Dota 2\n"))
        #expect(text.contains("⌥header MX Master 3S, Off in Dota 2, 800 DPI · Wheel: ratchet · v0.3.0"))
        // A state in passing: no badge and no row of its own.
        #expect(!Self.offState().needsAttention)
    }

    @Test func offInTheAppAddsNoRow() {
        var on = Self.offState()
        on.frontmostIsOff = false
        let withoutLine = lines(on).split(separator: "\n").count
        #expect(lines(Self.offState()).split(separator: "\n").count == withoutLine)
        #expect(lines(on).hasPrefix("header MX Master 3S, USB receiver · Battery 80%\n"))
    }

    @Test func aProblemWinsOverOffInTheApp() {
        for state in [Status.Device.Applied.State.notApplied, .applying] {
            let device = Self.mouse(applied: .init(state: state))
            let text = lines(Self.offState([device]))
            let problem = state == .notApplied ? "Settings not applied" : "Applying settings…"
            #expect(text.hasPrefix("header MX Master 3S, \(problem)\n"), "\(state)")
            #expect(!text.contains("Off in Dota 2"))
        }
    }

    @Test func aSleepingMouseReadsAsleepAndAnotherMacIsNotOffHere() {
        var asleep = Self.mouse("a")
        asleep.online = false
        #expect(lines(Self.offState([asleep])).hasPrefix("header MX Master 3S, Asleep\n"))
        var away = Self.offState()
        away.away = true
        #expect(lines(away).hasPrefix("header MX Master 3S, On another Mac · USB receiver · Battery 80%\n"))
    }
}
