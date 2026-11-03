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
        #expect(Notice.inputMonitoringMessage(waiting: ["MX Anywhere 3S"]).contains("MX Anywhere 3S"))
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
        #expect(RunState.off.button.command == .start)
        #expect(RunState.running.button.command == .stop)
        #expect(RunState.paused.button.command == .stop)
    }

    @Test func theStatusRowNamesTheState() {
        #expect(RunState(daemonRunning: true, paused: false) == .running)
        #expect(RunState(daemonRunning: true, paused: true) == .paused)
        #expect(RunState(daemonRunning: false, paused: false) == .off)
        #expect([RunState.running, .paused, .off].map(\.word) == ["Running", "Paused", "Off"])
    }

    @Test func useLastWorkingConfigSaysWhatItReplaces() {
        let message = UseLastWorkingConfirmation.message(backupName: "config.json.bak")
        #expect(message.contains("replaces the whole config file"))
        #expect(message.contains("config.json.bak"))
        #expect(!UseLastWorkingConfirmation.button.hasSuffix("…"))
    }
}
