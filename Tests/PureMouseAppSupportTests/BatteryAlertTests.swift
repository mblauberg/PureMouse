import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

private func battery(_ percent: Int?, level: Status.Device.Battery.Level = .good, charging: Bool = false) -> Status.Device.Battery {
    .init(percent: percent, level: level, charging: charging)
}

private func reading(_ id: String, _ percent: Int, name: String = "MX", charging: Bool = false,
                     model: String? = nil, unit: String? = nil) -> BatteryAlertStore.Reading {
    .init(id: id, name: name, battery: battery(percent, charging: charging), model: model, unit: unit)
}

/// A reading of a mouse that reports a stable identity; `id` is its status device id, which may change.
private func unitReading(_ percent: Int, id: String = "r1:1", charging: Bool = false) -> BatteryAlertStore.Reading {
    reading(id, percent, charging: charging, model: "m000000000001", unit: "0a1b2c3d")
}

private let unitKey = "unit:m000000000001:0a1b2c3d"
private func notification(_ band: BatteryAlert.Band, key: String = unitKey) -> String { "battery.\(key).\(band.rawValue)" }

private func scratchStore() -> (BatteryAlertStore, URL) {
    let url = FileManager.default.temporaryDirectory.appending(path: "alerts-\(UUID().uuidString).json")
    return (BatteryAlertStore(url: url), url)
}

/// Low-battery warnings: when to post, and which delivered ones to take down.
struct BatteryAlertTests {
    @Test func theNotificationNamesTheMouseAndHowMuchIsLeft() {
        let low = BatteryAlert.message(for: .low, device: "MX Master 3S", battery: battery(20))
        #expect(low.title == "MX Master 3S battery low")
        #expect(low.body == "20% left. Charge it soon.")
        let critical = BatteryAlert.message(for: .critical, device: "MX Master 3S", battery: battery(5))
        #expect(critical.title == "MX Master 3S battery critical")
        #expect(critical.body == "5% left. Charge it now.")
        // A mouse that reports only a level has no percentage to give.
        let level = BatteryAlert.message(for: .low, device: "MX Anywhere 3", battery: battery(nil, level: .low))
        #expect(level.title == "MX Anywhere 3 battery low")
        #expect(level.body == "Charge it soon.")
    }

    @Test func firstReadingNeverNotifies() {
        #expect(BatteryAlert.evaluate(previous: nil, battery: battery(3)) == (nil, .critical))
        #expect(BatteryAlert.evaluate(previous: nil, battery: battery(18)).alert == nil)
    }

    @Test func notifiesOncePerDownwardCrossing() {
        var state = BatteryAlert.Band.none
        var alerts: [BatteryAlert.Band] = []
        for percent in [30, 21, 20, 19, 18, 10, 6, 5, 4, 4, 3] {
            let result = BatteryAlert.evaluate(previous: state, battery: battery(percent))
            state = result.state
            if let alert = result.alert { alerts.append(alert) }
        }
        #expect(alerts == [.low, .critical])
    }

    @Test func rearmsOnlyAboveTheBandPlusHysteresis() {
        var result = BatteryAlert.evaluate(previous: .low, battery: battery(23))
        #expect(result.alert == nil && result.state == .low)  // 23 is inside the hysteresis
        result = BatteryAlert.evaluate(previous: result.state, battery: battery(19))
        #expect(result.alert == nil)                           // no repeat on a dip
        result = BatteryAlert.evaluate(previous: .low, battery: battery(25))
        #expect(result.state == .none)
        #expect(BatteryAlert.evaluate(previous: result.state, battery: battery(20)).alert == .low)
    }

    @Test func chargingRearms() {
        let result = BatteryAlert.evaluate(previous: .critical, battery: battery(4, charging: true))
        #expect(result.alert == nil && result.state == .none)
    }

    @Test func criticalToLowRisesAtTenPercent() {
        #expect(BatteryAlert.evaluate(previous: .critical, battery: battery(10)).state == .low)
        #expect(BatteryAlert.evaluate(previous: .critical, battery: battery(9)).state == .critical)
    }

    @Test func levelOnlyMiceUseTheirLevels() {
        #expect(BatteryAlert.evaluate(previous: BatteryAlert.Band.none, battery: battery(nil, level: .low)).alert == .low)
        #expect(BatteryAlert.evaluate(previous: .low, battery: battery(nil, level: .critical)).alert == .critical)
        #expect(BatteryAlert.evaluate(previous: .low, battery: battery(nil, level: .good)).state == .none)
    }

    @Test func storeKeepsStateAcrossProcesses() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([reading("a", 40)])
        #expect(store.process([reading("a", 19)]).alerts.map(\.band) == [.low])
        var restarted = BatteryAlertStore(url: url)
        #expect(restarted.process([reading("a", 18)]).alerts.isEmpty)
    }

    @Test func identicallyNamedMiceKeepSeparateState() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([reading("r1:1", 80), reading("r2:1", 19)])
        for _ in 0..<3 {
            #expect(store.process([reading("r1:1", 80), reading("r2:1", 19)]).alerts.isEmpty)
        }
        #expect(store.process([reading("r1:1", 19), reading("r2:1", 19)]).alerts.map(\.key) == ["r1:1"])
    }

    @Test func firstReadingWithoutAStableIdentityOnlyRecords() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([reading("a", 21)])
        _ = store.process([])                                          // asleep or daemon off
        #expect(store.process([reading("a", 19)]).alerts.isEmpty)      // back below 20: silent
        #expect(store.process([reading("a", 4)]).alerts.map(\.band) == [.critical])
        // A model without a unit (or the reverse) is no stable identity.
        var half = BatteryAlertStore(url: url)
        _ = half.process([])
        #expect(half.process([reading("a", 3, model: "m000000000001")]).alerts.isEmpty)
        #expect(half.process([reading("a", 3, unit: "0a1b2c3d")]).alerts.isEmpty)
    }

    @Test func aFirstReadingWithAStableIdentityButNoRecordedBandOnlyRecords() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        #expect(store.process([unitReading(15)]).alerts.isEmpty)
        #expect(store.bands[unitKey] == .low)
        var restarted = BatteryAlertStore(url: url)
        #expect(restarted.process([unitReading(15)]).alerts.isEmpty)  // recorded: not announced twice
    }

    @Test func aStableMouseReconnectingBelowTwentyWarnsOnce() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([unitReading(60)])
        #expect(store.bands[unitKey] == BatteryAlert.Band.none)
        _ = store.process([])                                           // asleep: it drained while away
        let outcome = store.process([unitReading(15)])
        #expect(outcome.alerts.map(\.band) == [.low])
        #expect(outcome.alerts.map(\.notificationID) == [notification(.low)])
        #expect(store.process([unitReading(15)]).alerts.isEmpty)
        // The same after the menu app restarted, and under another status device id.
        var restarted = BatteryAlertStore(url: url)
        #expect(restarted.process([unitReading(15, id: "r2:3")]).alerts.isEmpty)  // already announced
        _ = restarted.process([])
        #expect(restarted.process([unitReading(4, id: "r2:3")]).alerts.map(\.band) == [.critical])
    }

    @Test func aStableMouseThatDrainedWhileTheAppWasNotRunningWarns() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([unitReading(60)])
        var restarted = BatteryAlertStore(url: url)
        #expect(restarted.process([unitReading(15)]).alerts.map(\.band) == [.low])
    }

    @Test func rechargingTakesDownTheDeliveredNotification() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([unitReading(60)])
        #expect(store.process([unitReading(15)]).alerts.map(\.band) == [.low])
        #expect(store.process([unitReading(22)]).remove.isEmpty)                  // inside the hysteresis
        #expect(store.process([unitReading(30)]).remove == [notification(.low)])  // at or above 25
        #expect(store.process([unitReading(31)]).remove.isEmpty)                  // once

        _ = store.process([unitReading(15)])
        #expect(store.process([unitReading(15, charging: true)]).remove == [notification(.low)])

        // Critical recovering a step takes down the critical one, not the low one it falls back to.
        _ = store.process([unitReading(60)])
        _ = store.process([unitReading(4)])
        #expect(store.process([unitReading(12)]).remove == [notification(.critical)])
    }

    @Test func rechargingWhileTheAppWasNotRunningStillTakesItDown() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([unitReading(60)])
        _ = store.process([unitReading(15)])
        var restarted = BatteryAlertStore(url: url)
        #expect(restarted.process([unitReading(80)]).remove == [notification(.low)])
    }

    @Test func aDeeperBandReplacesTheShallowerNotification() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([unitReading(60)])
        _ = store.process([unitReading(15)])
        let outcome = store.process([unitReading(4)])
        #expect(outcome.alerts.map(\.notificationID) == [notification(.critical)])
        #expect(outcome.remove == [notification(.low)])
    }

    @Test func switchingTheSettingOffTakesDownEveryTrackedNotificationOnce() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([unitReading(60), reading("b", 60)])
        _ = store.process([unitReading(15), reading("b", 4)])
        _ = store.process([reading("b", 4)])                         // the first mouse is asleep
        let off = store.process([reading("b", 4)], enabled: false)
        #expect(off.remove == [notification(.low), notification(.critical, key: "b")].sorted())
        #expect(off.alerts.isEmpty)
        #expect(store.process([reading("b", 4)], enabled: false).remove.isEmpty)
        // Switched on again: nothing old is announced, and a new crossing is.
        #expect(store.process([reading("b", 4)], enabled: true).alerts.isEmpty)
        var fresh = BatteryAlertStore(url: url)
        #expect(fresh.process([], enabled: false).remove.count == 2)  // a restart with the setting off
    }

    @Test func disabledSettingNeverNotifiesButKeepsState() {
        let (first, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = first
        _ = store.process([reading("a", 30)], enabled: false)
        #expect(store.process([reading("a", 19)], enabled: false).alerts.isEmpty)
        #expect(store.process([reading("a", 18)], enabled: true).alerts.isEmpty)  // already recorded as low
        // A persisted state with the mouse live at startup: silent whatever the setting.
        var restarted = BatteryAlertStore(url: url)
        #expect(restarted.process([reading("a", 19)], enabled: true).alerts.isEmpty)
        // A stable mouse that drained while the setting was off is not announced when it is switched on.
        var stable = BatteryAlertStore(url: url)
        _ = stable.process([unitReading(60)], enabled: false)
        _ = stable.process([unitReading(15)], enabled: false)
        #expect(stable.process([unitReading(15)], enabled: true).alerts.isEmpty)
    }

    @Test func anUnreadableOrOldFileIsDiscarded() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "alerts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        for contents in ["not json", #"{"r1:1": "low"}"#, #"{"version": 1, "bands": {"r1:1": "low"}}"#,
                         #"{"version": 2, "bands": {"r1:1": "dire"}}"#] {
            try Data(contents.utf8).write(to: url)
            let store = BatteryAlertStore(url: url)
            #expect(store.bands.isEmpty, "\(contents)")
        }
        // Alerts start fresh, with the same hysteresis.
        try Data(#"{"r1:1": "low"}"#.utf8).write(to: url)
        var store = BatteryAlertStore(url: url)
        _ = store.process([reading("r1:1", 60)])
        #expect(store.process([reading("r1:1", 20)]).alerts.map(\.band) == [.low])
        #expect(store.process([reading("r1:1", 24)]).remove.isEmpty)
        #expect(store.process([reading("r1:1", 25)]).remove == ["battery.r1:1.low"])
        // What it writes, it reads back.
        #expect(BatteryAlertStore(url: url).bands == ["r1:1": BatteryAlert.Band.none])
    }

    // The wiring: a config change that switches the setting off takes the banners down at once.
    @MainActor @Test func switchingLowBatteryOffInTheConfigWithdrawsTheBanners() throws {
        let sandbox = try Sandbox()
        func status(_ percent: Int) -> Status {
            let device = Status.Device(id: "r1:1", name: "MX", connection: .receiver, online: true,
                                       battery: battery(percent), dpi: nil, dpiSteps: [], wheelMode: nil, controls: [],
                                       model: "m000000000001", unit: "0a1b2c3d")
            return daemonStatus(pid: getpid(), devices: [device])
        }
        var posted: [String] = []
        var withdrawn: [[String]] = []
        let model = AppModel(locations: sandbox.locations, alert: { _, _ in },
                             notifications: ({ id, _, _ in posted.append(id) }, { withdrawn.append($0) }))
        try sandbox.writeStatus(status(60))
        model.reloadStatus()
        try sandbox.writeStatus(status(15))
        model.reloadStatus()
        #expect(posted == [notification(.low)])
        #expect(withdrawn.isEmpty)
        try sandbox.write(#"{"notifications": {"lowBattery": false}}"#)
        model.reloadConfig()
        #expect(withdrawn == [[notification(.low)]])
    }

    // A run with its icon hidden gets no notification callbacks: it neither posts nor consumes
    // the band a reconnect would announce, so the next run with the icon still warns.
    @MainActor @Test func aModelWithoutNotificationsLeavesTheBandsAlone() throws {
        let sandbox = try Sandbox()
        func status(_ percent: Int) -> Status {
            let device = Status.Device(id: "r1:1", name: "MX", connection: .receiver, online: true,
                                       battery: battery(percent), dpi: nil, dpiSteps: [], wheelMode: nil, controls: [],
                                       model: "m000000000001", unit: "0a1b2c3d")
            return daemonStatus(pid: getpid(), devices: [device])
        }
        try Data(#"{"version":2,"bands":{"\#(unitKey)":"none"}}"#.utf8).writeCreatingDirectory(to: sandbox.locations.batteryAlerts)
        let hidden = AppModel(locations: sandbox.locations, alert: { _, _ in })
        try sandbox.writeStatus(status(15))
        hidden.reloadStatus()
        #expect(BatteryAlertStore(url: sandbox.locations.batteryAlerts).bands[unitKey] == BatteryAlert.Band.none)
        var posted: [String] = []
        let shown = AppModel(locations: sandbox.locations, alert: { _, _ in },
                             notifications: ({ id, _, _ in posted.append(id) }, { _ in }))
        shown.reloadStatus()
        #expect(posted == [notification(.low)])
    }
}

private extension Data {
    func writeCreatingDirectory(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(to: url)
    }
}
