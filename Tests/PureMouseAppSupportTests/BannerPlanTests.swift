import Testing
@testable import PureMouseAppSupport

@Suite struct BannerPlanTests {
    @Test func noticesComeInPriorityOrder() {
        let state = BannerPlan.State(configError: true, daemonRunning: false, logiOptionsRunning: true)
        #expect(BannerPlan.items(for: state) == [.configError, .off, .logiOptions])
    }

    @Test func everyNoticeAtOnceKeepsTheOrder() {
        let state = BannerPlan.State(configError: true, writeError: true, statusTooNew: true, daemonRunning: false,
                                     paused: true, logiOptionsRunning: true, accessibilityMissing: true,
                                     needsAccessibility: true, inputMonitoringNeeded: true, noMouse: true)
        #expect(BannerPlan.items(for: state)
            == [.configError, .writeError, .statusTooNew, .off, .paused, .inputMonitoring, .logiOptions,
                .accessibility, .noMouse])
        // The plan's order is the notices' own order, so a new notice cannot slip out of place.
        #expect(BannerPlan.items(for: state) == Notice.allCases)
        #expect(BannerPlan.items(for: BannerPlan.State()).isEmpty)
    }

    @Test func accessibilityShowsOnlyOnPanesThatNeedIt() {
        let missing = BannerPlan.State(accessibilityMissing: true)
        #expect(BannerPlan.items(for: missing).isEmpty)
        var needing = missing
        needing.needsAccessibility = true
        #expect(BannerPlan.items(for: needing) == [.accessibility])
        #expect(BannerPlan.items(for: BannerPlan.State(needsAccessibility: true)).isEmpty)
    }

    @Test func inputMonitoringAndNoMouseHaveTheirOwnNotices() {
        #expect(BannerPlan.items(for: BannerPlan.State(inputMonitoringNeeded: true)) == [.inputMonitoring])
        #expect(BannerPlan.items(for: BannerPlan.State(noMouse: true)) == [.noMouse])
        // A Bluetooth mouse waiting outranks Logi Options+ and Accessibility; no mouse comes last.
        let state = BannerPlan.State(logiOptionsRunning: true, accessibilityMissing: true, needsAccessibility: true,
                                     inputMonitoringNeeded: true, noMouse: true)
        #expect(BannerPlan.items(for: state).first == .inputMonitoring)
        #expect(BannerPlan.items(for: state).last == .noMouse)
    }

    /// The Logi Options+ notice offers to ask the app to quit and to open Login Items; no other
    /// notice carries these, and neither action signals or starts a process.
    @Test func theLogiOptionsNoticeOffersQuitAndLoginItems() {
        #expect(Notice.logiOptions.logiOptionsActions == [.quit])
        #expect(Notice.logiOptions.logiOptionsLink == .openLoginItems)
        for notice in Notice.allCases where notice != .logiOptions {
            #expect(notice.logiOptionsActions.isEmpty && notice.logiOptionsLink == nil, "\(notice)")
        }
        #expect(LogiOptionsAction.quit.title == "Quit Logi Options+")
        #expect(LogiOptionsAction.quit.url == nil)
        #expect(LogiOptionsAction.openLoginItems.title == "Open Login Items Settings…")
        #expect(LogiOptionsAction.openLoginItems.url == OpenAtLogin.settingsURL)
    }

    /// Quit asks the agent (the login item) and the app, by bundle identifier, and nothing else.
    @Test func quitReachesLogiOptionsAppsOnly() {
        #expect(LogiOptionsAction.isLogiOptions(bundleIdentifier: "com.logi.cp-dev-mgr"))
        #expect(LogiOptionsAction.isLogiOptions(bundleIdentifier: "com.logi.optionsplus"))
        #expect(LogiOptionsAction.isLogiOptions(bundleIdentifier: "com.logi.optionsplus.updater"))
        #expect(!LogiOptionsAction.isLogiOptions(bundleIdentifier: "io.github.mblauberg.puremouse.menu"))
        #expect(!LogiOptionsAction.isLogiOptions(bundleIdentifier: "com.logitech.manager"))
        #expect(!LogiOptionsAction.isLogiOptions(bundleIdentifier: nil))
    }

    /// General's Input Monitoring row says "Not needed" with no Bluetooth mouse, and offers the
    /// allow only when one needs it.
    @Test func aPermissionNobodyNeedsReadsNotNeeded() {
        #expect(PermissionState(granted: false, needed: false) == .notNeeded)
        #expect(PermissionState(granted: false, needed: false).word == "Not needed")
        #expect(PermissionState(granted: false, needed: true) == .notAllowed)
        #expect(PermissionState(granted: true, needed: false) == .allowed)
        #expect(PermissionState(granted: nil, needed: true) == .unavailable)
    }

    @Test func theInputMonitoringMessageNamesTheMiceOrBluetoothMice() {
        #expect(Notice.inputMonitoringTitle(waiting: ["MX Anywhere 3S"]) == "MX Anywhere 3S is waiting for Input Monitoring.")
        #expect(Notice.inputMonitoringTitle(waiting: ["MX Anywhere 3S", "M750"]) == "MX Anywhere 3S and M750 are waiting for Input Monitoring.")
        #expect(Notice.inputMonitoringTitle(waiting: ["A", "B", "C"]) == "A, B and C are waiting for Input Monitoring.")
        #expect(Notice.inputMonitoringTitle(waiting: []) == "PureMouse needs Input Monitoring.")
        #expect(Notice.inputMonitoringMessage(waiting: ["MX Anywhere 3S"])
                == "PureMouse can't see it until you allow it in System Settings. It restarts itself once you do.")
        #expect(Notice.inputMonitoringMessage(waiting: ["A", "B"]).contains("can't see them"))
        #expect(Notice.inputMonitoringMessage(waiting: []).contains("your Bluetooth mouse"))
    }

    @Test func aBannerCountsTheNoticesBehindIt() {
        #expect(BannerPlan.moreText(0) == nil)
        #expect(BannerPlan.moreText(1) == "1 more notice")
        #expect(BannerPlan.moreText(3) == "3 more notices")
    }

    /// Start on the off banner and in General starts PureMouse now and leaves Open at login alone:
    /// `start`, never `register` (ADR 18).
    @Test func startRunsStartAndNeverRegisters() {
        #expect(Notice.off.loginAction?.command == .start)
        #expect(Notice.off.loginAction?.command.arguments == ["start"])
        for notice in Notice.allCases where notice != .off { #expect(notice.loginAction == nil) }
        // General's switch pauses and resumes; Start is the only run control Settings offers, and only while off.
        #expect(RunState.off.button?.command == .start)
        #expect(RunState.running.button == nil)
        #expect(RunState.paused.button == nil)
    }

    /// The switch is on while active, moves to active or paused, and is not offered while off.
    @Test func theSwitchMapsToTheRunState() {
        #expect(RunState.running.isOn)
        #expect(!RunState.paused.isOn)
        #expect(!RunState.off.isOn)
        for state in [RunState.running, .paused] {
            #expect(state.toggled(true) == .running)
            #expect(state.toggled(false) == .paused)
        }
        #expect(RunState.off.toggled(true) == nil)
        #expect(RunState.off.toggled(false) == nil)
    }

    /// Off and paused are General's PureMouse row, so its list of notices leaves them out; every other
    /// notice still shows there, and a pane's banner still offers them.
    @Test func generalListsNoNoticeThatItsPureMouseRowIs() {
        let off = BannerPlan.State(daemonRunning: false, paused: false)
        let paused = BannerPlan.State(daemonRunning: true, paused: true)
        #expect(BannerPlan.items(for: off) == [.off])
        #expect(BannerPlan.items(for: paused) == [.paused])
        #expect(BannerPlan.generalItems(for: off).isEmpty)
        #expect(BannerPlan.generalItems(for: paused).isEmpty)
        let more = BannerPlan.State(daemonRunning: true, paused: true, logiOptionsRunning: true,
                                    accessibilityMissing: true, needsAccessibility: true, noMouse: true)
        #expect(BannerPlan.generalItems(for: more) == [.logiOptions, .accessibility, .noMouse])
    }

    @Test func theStatusRowNamesTheState() {
        #expect(RunState(daemonRunning: true, paused: false) == .running)
        #expect(RunState(daemonRunning: true, paused: true) == .paused)
        #expect(RunState(daemonRunning: false, paused: false) == .off)
        #expect([RunState.running, .paused, .off].map(\.word) == ["Active", "Paused", "Off"])
    }

    @Test func useLastWorkingConfigSaysWhatItReplaces() {
        let message = UseLastWorkingConfirmation.message(backupName: "config.json.bak")
        #expect(message.contains("replaces the whole config file"))
        #expect(message.contains("config.json.bak"))
        #expect(!UseLastWorkingConfirmation.button.hasSuffix("…"))
    }
}

@Suite struct OneObservationEachTests {
    @Test func askingTwiceKeepsOneObservationPerProcess() {
        var held = OneObservationEach<Int, String>()
        var made = 0
        #expect(held.start(10) { made += 1; return "a" })
        #expect(!held.start(10) { made += 1; return "b" })
        #expect(held.start(11) { made += 1; return "c" })
        #expect(made == 2 && held.count == 2)
    }

    @Test func aQuitProcessReleasesItsObservation() {
        var held = OneObservationEach<Int, String>()
        held.start(10) { "a" }
        held.finish(10)
        #expect(held.count == 0)
        #expect(held.start(10) { "again" }, "a later ask for the same pid is watched afresh")
    }
}
