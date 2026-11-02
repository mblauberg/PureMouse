import AppKit
import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseMenu

/// A scheduler that records what it was asked and runs nothing.
@MainActor
final class InertScheduler: UpdateScheduling {
    var delays: [TimeInterval] = []
    func schedule(after delay: TimeInterval, work: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void) {
        delays.append(delay)
    }
    func cancel() {}
}

extension UpdateSetup {
    /// Nothing live: its own preferences, a scheduler that never fires, a fetcher that fails the test
    /// if it is called, and answers the question as told.
    @MainActor static func inert(preferences: UpdatePreferences, scheduler: UpdateScheduling = InertScheduler(),
                                 ask: @escaping @MainActor () -> Bool = { false },
                                 announce: @escaping @MainActor (UpdateOffer) -> Void = { _ in }) -> UpdateSetup {
        UpdateSetup(preferences: preferences, current: "0.5.0",
                    fetcher: { _ in Issue.record("a request was made"); throw URLError(.cancelled) },
                    scheduler: scheduler, ask: ask, announce: announce)
    }
}

/// The question about automatic checks, asked of the person once.
@MainActor
struct AppControllerUpdateTests {
    private let directory: URL
    private let locations: Locations
    private let suite = "PureMouseMenuUpdates-\(UUID().uuidString)"
    private let preferences: UpdatePreferences
    private let scheduler = InertScheduler()
    private var questions = Counter()
    private var withdrawn = Log()

    final class Counter { var asked = 0; var answer = true }
    final class Log { var ids: [[String]] = [] }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pm-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        locations = Locations(config: directory.appending(path: "config.json"),
                              log: directory.appending(path: "PureMouse.log"), daemon: nil,
                              companion: directory.appending(path: "companion", directoryHint: .isDirectory))
        preferences = UpdatePreferences(UserDefaults(suiteName: suite)!)
    }

    private func writeStatus(accessibility: Bool = true, running: Bool = true) throws {
        let status = Status(pid: getpid(), startedAt: Date(timeIntervalSince1970: 0), version: "0.5.0", running: running,
                            paused: false, permissions: .init(accessibility: accessibility, inputMonitoring: true),
                            logiOptionsRunning: false, config: .init(path: locations.config.path, error: nil),
                            devices: [], capture: nil)
        try Companion.write(status, to: locations.status)
    }

    /// One launch of the menu app: a new controller over the same preferences.
    private func launch(iconShown: Bool = true) -> AppController {
        let questions = questions
        let setup = UpdateSetup.inert(preferences: preferences, scheduler: scheduler,
                                      ask: { questions.asked += 1; return questions.answer })
        let withdrawn = withdrawn
        let controller = AppController(locations: locations, iconShown: iconShown, announce: { _, _, _ in },
                                       withdraw: { withdrawn.ids.append($0) }, requestPermission: {}, updates: setup)
        controller.startUpdates()
        return controller
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func nothingIsAskedOnTheFirstLaunchAndTheQuestionShowsOnceOnTheSecond() async throws {
        try writeStatus()
        _ = launch()
        await settle { false }
        #expect(questions.asked == 0 && preferences.automatic == nil)
        _ = launch()
        await settle { questions.asked > 0 }
        #expect(questions.asked == 1)
        #expect(preferences.automatic == true)
        #expect(scheduler.delays == [0])  // the check is scheduled, not run
        for _ in 0..<3 { _ = launch() }
        await settle { false }
        #expect(questions.asked == 1)
    }

    @Test func doNotCheckIsRememberedAndNeverSchedulesAnything() async throws {
        questions.answer = false
        try writeStatus()
        _ = launch()
        _ = launch()
        await settle { questions.asked > 0 }
        #expect(preferences.automatic == false)
        _ = launch()
        await settle { false }
        #expect(questions.asked == 1 && scheduler.delays.isEmpty)
    }

    @Test func missingPermissionsPutTheQuestionOffToALaterLaunch() async throws {
        try writeStatus(accessibility: false)
        _ = launch()
        _ = launch()
        await settle { false }
        #expect(questions.asked == 0)
        try writeStatus(accessibility: true)
        _ = launch()
        await settle { questions.asked > 0 }
        #expect(questions.asked == 1)
    }

    @Test func aDaemonThatIsNotRunningDoesNotCountAsSetUp() async throws {
        try writeStatus(running: false)
        _ = launch()
        _ = launch()
        await settle { false }
        #expect(questions.asked == 0)
    }

    @Test func aStatusWrittenAfterLaunchStillGetsTheQuestionThisRun() async throws {
        _ = launch()
        let second = launch()  // no status yet, as at login before the daemon writes one
        await settle { false }
        #expect(questions.asked == 0)
        try writeStatus()
        second.model.reloadStatus()
        second.statusChanged()
        await settle { questions.asked > 0 }
        #expect(questions.asked == 1)
    }

    @Test func aRunWithoutTheIconNeitherCountsNorAsksNorSchedules() async throws {
        try writeStatus()
        for _ in 0..<4 { _ = launch(iconShown: false) }
        await settle { false }
        #expect(preferences.launches == 0 && questions.asked == 0 && scheduler.delays.isEmpty)
    }

    @Test func skippingAVersionTakesItsNotificationDown() async throws {
        preferences.automatic = true
        preferences.latest = UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!, page: URL(string: "https://example.com/r")!)
        let controller = launch()
        #expect(controller.updates.offer?.menuTitle == "Update to 0.6.0…")
        controller.skipUpdate()
        #expect(controller.updates.offer == nil)
        #expect(withdrawn.ids.last == ["update.0.6.0"])
    }

    @Test func theQuestionAsksWhatTheIssueSaysWithItsTwoButtons() {
        let alert = Alerts.updateQuestion()
        #expect(alert.messageText == "Check for updates automatically?")
        #expect(alert.informativeText == "PureMouse can ask GitHub once a day whether a new release is out, and tell you if one is. It never installs anything by itself. You can change this in Settings › About.")
        #expect(alert.buttons.map(\.title) == ["Check Automatically", "Don't Check"])
        #expect(alert.buttons.first?.keyEquivalent == "\r")
    }

    @Test func aClickedReminderOpensOnlyAnHttpsPage() {
        #expect(Notifier.page(in: [Notifier.pageKey: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0"])?.host == "github.com")
        #expect(Notifier.page(in: [Notifier.pageKey: "file:///etc/passwd"]) == nil)
        #expect(Notifier.page(in: [Notifier.pageKey: "http://example.com"]) == nil)
        #expect(Notifier.page(in: [:]) == nil)
    }
}
