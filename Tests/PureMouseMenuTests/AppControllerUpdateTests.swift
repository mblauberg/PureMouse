import AppKit
import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
import UserNotifications
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

/// Something an install waits on until the test lets it go; asking it to cancel lets it go too, as a
/// cancelled download does.
final class Suspended: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var cancelledFlag = false

    var cancelled: Bool { lock.withLock { cancelledFlag } }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released { lock.unlock(); continuation.resume() } else { self.continuation = continuation; lock.unlock() }
        }
    }

    func release(cancelled: Bool = false) {
        lock.lock()
        released = true
        if cancelled { cancelledFlag = true }
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

/// What the install row did, recorded.
@MainActor
final class InstallSpy {
    var outcome: UpdateInstallOutcome = .installed(UpdateCheck.Version("0.6.0")!)
    var confirm = true
    var relaunchWorks = true
    var confirmed: [UpdateOffer] = []
    var installs: [(release: UpdateCheck.Release, current: String, app: URL?)] = []
    var relaunched: [URL] = []
    var relaunchSources: [InstallSource] = []
    var opened: [URL] = []
    var terminated = 0
    var alerts: [String] = []
    var replies: [Bool] = []
    /// When set, the install waits here until released or cancelled; then, if `cleanup` is set,
    /// waits there too, as detaching the image and deleting the download do.
    var gate: Suspended?
    var cleanup: Suspended?
    /// Runs while the confirmation is up, as another request arriving during the modal alert does.
    var duringConfirm: (@MainActor () -> Void)?
    /// Stands in for the whole relaunch, to run the real `relaunchLive` over a fake Settings helper.
    var relaunchOverride: (@MainActor (URL, InstallSource) async -> Relaunch)?
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
    private func launch(iconShown: Bool = true, resident: Bool? = nil) -> AppController {
        let questions = questions
        let setup = UpdateSetup.inert(preferences: preferences, scheduler: scheduler,
                                      ask: { questions.asked += 1; return questions.answer })
        let withdrawn = withdrawn
        let controller = AppController(locations: locations, iconShown: iconShown, resident: resident, announce: { _, _, _ in },
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

    @Test func aStaleStatusFromBeforeLoginDoesNotSettleTheQuestion() async throws {
        try writeStatus(running: false)  // the last run's file, still on disk at login
        _ = launch()
        let second = launch()
        await settle { false }
        #expect(questions.asked == 0)
        try writeStatus(running: true)   // the daemon starts and writes its own
        second.model.reloadStatus()
        second.statusChanged()
        await settle { questions.asked > 0 }
        #expect(questions.asked == 1)
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

    /// Show in menu bar off hides the status item, not the process: the launchd-run menu app goes on
    /// counting launches, scheduling the check and asking the question (docs/ui-design.md).
    @Test func theResidentRunWithoutTheIconStillCountsAsksAndSchedules() async throws {
        try writeStatus()
        _ = launch(iconShown: false, resident: true)
        let second = launch(iconShown: false, resident: true)
        await settle { questions.asked > 0 }
        #expect(questions.asked == 1)
        #expect(preferences.automatic == true)
        #expect(!scheduler.delays.isEmpty)  // the check is scheduled, not run
        _ = second
    }

    @Test func turningTheChecksOffTakesTheDeliveredReminderDown() {
        preferences.automatic = true
        preferences.latest = UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!, page: URL(string: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0")!)
        preferences.notified = [UpdateCheck.Version("0.6.0")!]  // the reminder was delivered
        let controller = launch()
        controller.updates.setAutomatic(false)
        #expect(controller.updates.offer == nil)
        #expect(withdrawn.ids.last == ["update.0.6.0"])
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

    @Test func clickingTheReminderOpensItsPageAndAnythingElseDoesNot() {
        let info: [AnyHashable: Any] = [Notifier.pageKey: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0"]
        var opened: [URL] = []
        let page = Notifier.page(in: info)
        Notifier.handleClick(action: UNNotificationDefaultActionIdentifier, page: page) { opened.append($0) }
        #expect(opened.map(\.absoluteString) == ["https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0"])
        Notifier.handleClick(action: UNNotificationDismissActionIdentifier, page: page) { opened.append($0) }
        Notifier.handleClick(action: UNNotificationDefaultActionIdentifier, page: Notifier.page(in: [:])) { opened.append($0) }
        Notifier.handleClick(action: UNNotificationDefaultActionIdentifier,
                             page: Notifier.page(in: [Notifier.pageKey: "file:///etc/passwd"])) { opened.append($0) }
        #expect(opened.count == 1)
    }

    // MARK: Installing

    private static let page = URL(string: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0")!
    private static let app = URL(fileURLWithPath: "/Applications/PureMouse.app")

    /// A launch with 0.6.0 on offer and every outside effect recorded.
    private func offered(_ spy: InstallSpy,
                         menuOff: ((@escaping @MainActor (Bool) -> Void) -> Void)? = nil) -> AppController {
        preferences.automatic = true
        preferences.latest = UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!, page: Self.page)
        var setup = UpdateSetup.inert(preferences: preferences, scheduler: scheduler)
        setup.installedApp = Self.app
        setup.confirm = { spy.confirmed.append($0); spy.duringConfirm?(); return spy.confirm }
        setup.install = { release, current, app in
            await MainActor.run { spy.installs.append((release, current, app)) }
            if let gate = await spy.gate {
                await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.release(cancelled: true) }
                if let cleanup = await spy.cleanup { await cleanup.wait() }
                if gate.cancelled { return .failed(.cancelled) }
            }
            return await spy.outcome
        }
        setup.relaunch = {
            if let relaunch = spy.relaunchOverride { return await relaunch($0, $1) }
            spy.relaunched.append($0); spy.relaunchSources.append($1)
            return spy.relaunchWorks ? .started : .failed
        }
        setup.openPage = { spy.opened.append($0) }
        setup.terminate = { spy.terminated += 1 }
        setup.alert = { title, _ in spy.alerts.append(title) }
        setup.replyToTerminate = { spy.replies.append($0) }
        return AppController(locations: locations, iconShown: true, announce: { _, _, _ in },
                             withdraw: { _ in }, requestPermission: {}, updates: setup, menuOff: menuOff)
    }

    /// Hiding the icon leaves the process running, so it must not turn later installs away; one
    /// that fails to hide does not either.
    @Test(arguments: [true, false])
    func installsAreAcceptedAgainAfterHidingTheIcon(hideWorks: Bool) async {
        let spy = InstallSpy()
        var hides = 0
        let controller = offered(spy, menuOff: { done in hides += 1; done(hideWorks) })
        controller.hideMenuBarIcon()
        await settle { false }
        #expect(hides == 1)
        controller.installUpdate()
        await settle { spy.installs.count == 1 }
        #expect(spy.confirmed.count == 1 && spy.installs.count == 1)
    }

    /// While the hide is still running (its command not yet answered) an install is held back.
    @Test func anInstallWaitsForAHideInProgress() async {
        let spy = InstallSpy()
        var finish: (@MainActor (Bool) -> Void)?
        let controller = offered(spy, menuOff: { finish = $0 })
        controller.hideMenuBarIcon()
        await settle { finish != nil }
        controller.installUpdate()
        await settle { false }
        #expect(spy.confirmed.isEmpty && spy.installs.isEmpty)
        finish?(true)
        controller.installUpdate()
        await settle { spy.installs.count == 1 }
        #expect(spy.installs.count == 1)
    }

    @Test func choosingUpdateAsksFirstAndInstallsOnlyOnAYes() async {
        let spy = InstallSpy()
        spy.confirm = false
        let controller = offered(spy)
        controller.installUpdate()
        await settle { false }
        #expect(spy.confirmed.map(\.version.text) == ["0.6.0"])
        #expect(spy.installs.isEmpty && controller.installState == .idle)
    }

    @Test func aGoodInstallRelaunchesTheInstalledAppAndEndsThisOne() async {
        let spy = InstallSpy()
        let controller = offered(spy)
        controller.installUpdate()
        #expect(controller.installState == .installing)
        await settle { spy.terminated > 0 }
        #expect(spy.installs.count == 1 && spy.installs[0].release.page == Self.page)
        #expect(spy.installs[0].current == "0.5.0" && spy.installs[0].app == Self.app)
        #expect(spy.relaunched == [Self.app] && spy.terminated == 1 && spy.opened.isEmpty)
    }

    @Test func aRefusalShowsItsReasonAndLeavesThisAppRunning() async {
        let spy = InstallSpy()
        spy.outcome = .failed(.checksumMismatch)
        let controller = offered(spy)
        controller.installUpdate()
        await settle { controller.installState != .installing }
        #expect(controller.installState == .failed(reason: "The download doesn't match its checksum", retry: true))
        #expect(spy.relaunched.isEmpty && spy.terminated == 0 && spy.opened.isEmpty)
    }

    @Test func aCopyThatCannotBeReplacedOpensTheReleasePageWithoutAnotherTry() async {
        let spy = InstallSpy()
        spy.outcome = .failed(.cannotInstallHere(.notWritable))
        let controller = offered(spy)
        controller.installUpdate()
        await settle { controller.installState != .installing }
        #expect(spy.opened == [Self.page])
        guard case .failed(let reason, let retry) = controller.installState else { Issue.record("not failed"); return }
        #expect(!retry && reason == UpdateInstallFailure.cannotInstallHere(.notWritable).reason)
        #expect(spy.terminated == 0)
    }

    @Test func aSecondChoiceWhileInstallingDoesNothing() async {
        let spy = InstallSpy()
        let controller = offered(spy)
        controller.installUpdate()
        controller.installUpdate()
        await settle { spy.terminated > 0 }
        #expect(spy.confirmed.count == 1 && spy.installs.count == 1)
    }

    @Test func nothingIsInstalledWhenNothingIsOffered() async {
        let spy = InstallSpy()
        let controller = offered(spy)
        preferences.latest = nil
        controller.installUpdate()
        await settle { false }
        #expect(spy.confirmed.isEmpty && spy.installs.isEmpty)
    }

    @Test func anUpdatedAppThatWillNotReopenSaysSoAndStaysUp() async {
        let spy = InstallSpy()
        spy.relaunchWorks = false
        let controller = offered(spy)
        controller.installUpdate()
        await settle { !spy.relaunched.isEmpty }
        #expect(spy.terminated == 0 && spy.alerts == ["PureMouse is updated."])
        // The new app is on disk: the row that offered it is gone, not an invitation to install again.
        #expect(controller.installState == .installed)
    }

    @Test func afterAFailedRelaunchSettingsStillOpens() async {
        let fake = FakeSystem()
        let launcher = SettingsLauncher(system: fake.system)
        var asked: [URL] = []
        let opened = await UpdateSetup.relaunchLive(Self.app, from: .menu, launcher: launcher) { app, _ in asked.append(app); return false }
        #expect(opened == .failed && asked == [Self.app])
        // Quitting for the relaunch is not Quit PureMouse: no stamp, and the next open goes ahead.
        #expect(fake.quitMarks == 0)
        launcher.open(ShowRequest())
        #expect(fake.opens.count == 1 && fake.posts.count == 1)
    }

    @Test func theHelperIsQuitBeforeTheAppIsOpened() async {
        let fake = FakeSystem()
        let helper = FakeSystem.Helper(alive: true)
        fake.running = [helper]
        var quitsWhenOpened = -1
        _ = await UpdateSetup.relaunchLive(Self.app, from: .menu, launcher: SettingsLauncher(system: fake.system)) { _, _ in
            quitsWhenOpened = helper.quitCount
            return true
        }
        #expect(quitsWhenOpened == 1)
    }

    // MARK: Settings across the relaunch

    /// Runs `relaunchLive` and records what was asked of the new copy, and of Settings by this process.
    private func relaunch(from source: InstallSource, settingsRunning: Bool) async -> (fake: FakeSystem, reopening: ShowRequest??, helper: FakeSystem.Helper) {
        let fake = FakeSystem()
        let helper = FakeSystem.Helper(alive: settingsRunning)
        fake.running = settingsRunning ? [helper] : []
        var reopening: ShowRequest??
        _ = await UpdateSetup.relaunchLive(Self.app, from: source, launcher: SettingsLauncher(system: fake.system)) { _, reopen in
            reopening = .some(reopen)
            return true
        }
        return (fake, reopening, helper)
    }

    @Test func aMenuRowInstallWithoutSettingsOpenAsksForNoSettingsWindow() async {
        let run = await relaunch(from: .menu, settingsRunning: false)
        #expect(run.reopening == .some(nil))
        #expect(run.fake.posts.isEmpty && run.fake.opens.isEmpty)
    }

    /// This process is replaced by `register`, and a helper that is quitting takes a request and
    /// exits, so the old process opening Settings is lost twice over. The new copy does it.
    @Test func aMenuRowInstallWithSettingsOpenLeavesReopeningItToTheNewCopy() async {
        let run = await relaunch(from: .menu, settingsRunning: true)
        #expect(run.helper.quitCount == 1)
        #expect(run.reopening == .some(ShowRequest()))
        #expect(run.fake.posts.isEmpty && run.fake.opens.isEmpty, "this process asks for nothing: it is about to be replaced")
    }

    @Test func anAboutInstallLeavesReopeningSettingsOnAboutToTheNewCopy() async {
        let run = await relaunch(from: .about, settingsRunning: true)
        #expect(run.reopening == .some(ShowRequest(pane: .tab(.about))))
        #expect(run.fake.posts.isEmpty && run.fake.opens.isEmpty)
    }

    @Test func anAboutInstallAsksForAboutEvenIfSettingsHadJustGone() async {
        let run = await relaunch(from: .about, settingsRunning: false)
        #expect(run.reopening == .some(ShowRequest(pane: .tab(.about))))
    }

    /// The old helper reads a request the new copy posts, and only then handles the quit queued ahead
    /// of it: it exits with Settings gone and nothing to retry. So the new copy is not started until
    /// the helper has gone.
    @Test func theNewCopyIsNotStartedWhileTheHelperIsStillExiting() async {
        let fake = FakeSystem()
        let helper = FakeSystem.Helper(alive: true)
        helper.exitsOnQuit = false
        fake.running = [helper]
        var opened = 0
        let launcher = SettingsLauncher(system: fake.system)
        let task = Task { @MainActor in
            await UpdateSetup.relaunchLive(Self.app, from: .about, launcher: launcher) { _, _ in opened += 1; return true }
        }
        await settle { false }
        #expect(helper.quitCount == 1 && opened == 0, "asked to quit, not yet gone")
        for _ in 0..<5 { fake.runDelayed(); await settle { false } }
        #expect(opened == 0, "still waiting while it is alive")
        helper.exit()
        fake.runDelayed()
        #expect(await task.value == .started)
        #expect(opened == 1)
    }

    @Test func theNewCopyIsStartedAfterTheTimeoutIfTheHelperNeverExits() async {
        let fake = FakeSystem()
        let helper = FakeSystem.Helper(alive: true)
        helper.exitsOnQuit = false
        fake.running = [helper]
        var opened = 0
        let launcher = SettingsLauncher(system: fake.system)
        let task = Task { @MainActor in
            await UpdateSetup.relaunchLive(Self.app, from: .menu, launcher: launcher) { _, _ in opened += 1; return true }
        }
        var waited: TimeInterval = 0
        while opened == 0, waited < 10 {
            await settle { false }
            waited += fake.delayed.map(\.0).reduce(0, +)
            fake.runDelayed()
        }
        #expect(await task.value == .started)
        #expect(opened == 1)
        #expect(waited >= SettingsLauncher.quitWait && waited < SettingsLauncher.quitWait + 1, "about 3 s, then on regardless")
    }

    @Test func nothingIsWaitedForWhenSettingsIsNotRunning() async {
        let fake = FakeSystem()
        var opened = 0
        _ = await UpdateSetup.relaunchLive(Self.app, from: .menu, launcher: SettingsLauncher(system: fake.system)) { _, _ in opened += 1; return true }
        #expect(opened == 1 && fake.delayed.isEmpty)
    }

    @Test func theRelaunchOpensTheNewCopyToRegisterAndNothingMore() {
        #expect(UpdateRelaunch.arguments(for: Self.app, reopening: nil)
                == ["-n", Self.app.path, "--args", "register", "--relaunch"])
    }

    @Test func theRelaunchCarriesWhichPaneToReopenIntoTheNewCopy() {
        #expect(UpdateRelaunch.arguments(for: Self.app, reopening: ShowRequest(pane: .tab(.about)))
                == ["-n", Self.app.path, "--args", "register", "--relaunch", "--settings=about"])
        // Empty: the pane Settings last showed.
        #expect(UpdateRelaunch.arguments(for: Self.app, reopening: ShowRequest())
                == ["-n", Self.app.path, "--args", "register", "--relaunch", "--settings="])
    }

    @Test func theMenuRowAndAboutTellTheRelaunchWhereTheyCameFrom() async {
        for (source, start) in [(InstallSource.menu, { (c: AppController) in c.installUpdate() }),
                                (InstallSource.about, { (c: AppController) in
                                    self.preferences.installRequest = UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!, page: Self.page)
                                    c.installRequested() })] {
            let spy = InstallSpy()
            let controller = offered(spy)
            start(controller)
            await settle { spy.terminated > 0 }
            #expect(spy.relaunchSources == [source])
        }
    }

    // MARK: One installer, also while confirming

    @Test func aRequestThatArrivesWhileConfirmingIsRefusedSoOnlyOneInstallRuns() async {
        let spy = InstallSpy()
        spy.gate = Suspended()
        let controller = offered(spy)
        spy.duringConfirm = { [unowned controller] in
            spy.duringConfirm = nil
            controller.installUpdate()   // the menu row again
            controller.startInstall(UpdateOffer(version: UpdateCheck.Version("0.6.0")!, page: Self.page), from: .about)   // About's request
        }
        controller.installUpdate()
        await settle { false }
        #expect(spy.confirmed.count == 1, "the second request did not open a second alert")
        #expect(spy.installs.count == 1)
        var ended = false
        controller.afterInstallEnds { ended = true }
        spy.gate?.release(cancelled: true)
        await settle { ended }
        #expect(ended && spy.installs.count == 1 && spy.relaunched.isEmpty)
    }

    @Test func aRequestFromAboutDuringTheMenusConfirmationStartsNothingMore() async {
        let spy = InstallSpy()
        spy.gate = Suspended()
        let controller = offered(spy)
        spy.duringConfirm = { [unowned controller] in
            spy.duringConfirm = nil
            self.preferences.installRequest = UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!, page: Self.page)
            controller.installRequested()
        }
        controller.installUpdate()
        await settle { false }
        #expect(spy.confirmed.count == 1 && spy.installs.count == 1)
        #expect(preferences.installRequest == nil)
        spy.gate?.release(cancelled: true)
        await settle { false }
    }

    @Test func quittingWhileTheConfirmationIsUpInstallsNothingAfterIt() async {
        let spy = InstallSpy()
        let controller = offered(spy)
        var ended = false
        spy.duringConfirm = { [unowned controller] in controller.afterInstallEnds { ended = true } }
        controller.installUpdate()
        await settle { false }
        #expect(ended)
        #expect(spy.installs.isEmpty && controller.installState == .idle)
    }

    // MARK: Lifecycle while installing

    private func suspended(_ spy: InstallSpy) -> AppController {
        spy.gate = Suspended()
        let controller = offered(spy)
        controller.installUpdate()
        return controller
    }

    @Test func quitWaitsForAnInstallToCancelAndCleanUp() async {
        let spy = InstallSpy()
        spy.cleanup = Suspended()
        let controller = suspended(spy)
        await settle { false }
        var ended = false
        controller.afterInstallEnds { ended = true }
        await settle { false }
        #expect(spy.gate?.cancelled == true, "the install was told to stop")
        #expect(!ended, "but quitting waits for its cleanup")
        spy.cleanup?.release()
        await settle { ended }
        #expect(ended && controller.installState == .idle && spy.relaunched.isEmpty)
    }

    @Test func quitWithNothingInstallingGoesAtOnce() {
        let controller = offered(InstallSpy())
        var ended = false
        controller.afterInstallEnds { ended = true }
        #expect(ended)
    }

    @Test func terminationIsDeferredWhileInstallingAndAnsweredAfterTheCleanup() async {
        let spy = InstallSpy()
        spy.cleanup = Suspended()
        let controller = suspended(spy)
        await settle { false }
        #expect(controller.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        await settle { false }
        #expect(spy.replies.isEmpty)
        spy.cleanup?.release()
        await settle { !spy.replies.isEmpty }
        #expect(spy.replies == [true])
    }

    @Test func terminationIsImmediateWhenNothingIsInstalling() {
        #expect(offered(InstallSpy()).applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test func anInstallThatCommitsWhileQuittingDoesNotRelaunch() async {
        let spy = InstallSpy()
        spy.gate = Suspended()
        spy.cleanup = nil
        let controller = offered(spy)
        controller.installUpdate()
        await settle { false }
        var ended = false
        controller.afterInstallEnds { ended = true }
        spy.outcome = .installed(UpdateCheck.Version("0.6.0")!)
        // Cancelling lets the fake return .cancelled; make it commit instead, as one past the swap does.
        spy.gate?.release()
        await settle { ended }
        #expect(ended && spy.relaunched.isEmpty && spy.terminated == 0)
    }

    /// Quit or Hide chosen while the relaunch waits for Settings to exit: the update is on disk, the
    /// choice stands, and the new copy starts at the next login. No second start, no alert.
    @Test func quittingWhileTheRelaunchWaitsForSettingsStartsNothing() async {
        let spy = InstallSpy()
        let fake = FakeSystem()
        let helper = FakeSystem.Helper(alive: true)
        helper.exitsOnQuit = false
        fake.running = [helper]
        var opened = 0
        let launcher = SettingsLauncher(system: fake.system)
        spy.relaunchOverride = { app, source in
            await UpdateSetup.relaunchLive(app, from: source, launcher: launcher) { _, _ in opened += 1; return true }
        }
        let controller = offered(spy)
        controller.installUpdate()
        await settle { helper.quitCount > 0 }
        #expect(helper.quitCount == 1 && opened == 0)
        var ended = false
        controller.afterInstallEnds { ended = true }
        helper.exit()
        fake.runDelayed()
        await settle { ended }
        for _ in 0..<5 { fake.runDelayed(); await settle { false } }
        #expect(ended)
        #expect(opened == 0, "the replacement is not started")
        #expect(spy.terminated == 0 && spy.alerts.isEmpty, "no update termination, no failure alert")
    }

    @Test func aRelaunchWaitEndsEarlyWhenItsTaskIsCancelled() async {
        let fake = FakeSystem()
        let helper = FakeSystem.Helper(alive: true)
        helper.exitsOnQuit = false
        fake.running = [helper]
        let launcher = SettingsLauncher(system: fake.system)
        var opened = 0
        let task = Task { @MainActor in
            await UpdateSetup.relaunchLive(Self.app, from: .menu, launcher: launcher) { _, _ in opened += 1; return true }
        }
        await settle { false }
        task.cancel()
        fake.runDelayed()   // one look, with the helper still alive
        #expect(await task.value == .abandoned)
        #expect(opened == 0)
    }

    @Test func aSecondInstallCannotStartOnceQuittingBegan() async {
        let spy = InstallSpy()
        let controller = offered(spy)
        controller.afterInstallEnds {}
        controller.installUpdate()
        await settle { false }
        #expect(spy.confirmed.isEmpty && spy.installs.isEmpty)
    }

    @Test func aCancelledInstallIsNotShownAsAFailure() async {
        let spy = InstallSpy()
        spy.outcome = .failed(.cancelled)
        let controller = offered(spy)
        controller.installUpdate()
        await settle { controller.installState != .installing }
        #expect(controller.installState == .idle && spy.opened.isEmpty && spy.terminated == 0)
    }

    // MARK: Asked for from About

    private func aboutRequest(_ spy: InstallSpy, version: String = "0.6.0",
                              page: String = "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0") -> AppController {
        preferences.latest = nil   // nothing offered by the menu: About found it alone
        let controller = offered(spy)
        preferences.latest = nil
        controller.startUpdates()
        preferences.installRequest = UpdateCheck.Release(version: UpdateCheck.Version(version)!, page: URL(string: page)!)
        return controller
    }

    @Test func aRequestFromAboutAsksTheSameQuestionThenInstallsAndClearsIt() async {
        let spy = InstallSpy()
        spy.gate = Suspended()
        let controller = aboutRequest(spy)
        await settle { !spy.installs.isEmpty }
        #expect(spy.confirmed.map(\.version.text) == ["0.6.0"])
        #expect(spy.installs.count == 1 && spy.installs[0].release.page == Self.page)
        #expect(preferences.installRequest == nil)
        #expect(preferences.installStatus == "Updating to 0.6.0…")
        #expect(controller.installState == .installing)
        spy.gate?.release()
        await settle { spy.terminated > 0 }
        #expect(spy.relaunched == [Self.app] && spy.terminated == 1)
        #expect(preferences.installStatus == nil)
    }

    @Test func aRequestThatIsRefusedLeavesAboutItsReason() async {
        let spy = InstallSpy()
        spy.outcome = .failed(.wrongCertificate)
        let controller = aboutRequest(spy)
        defer { withExtendedLifetime(controller) {} }
        await settle { preferences.installStatus != nil }
        #expect(preferences.installStatus == "The update wasn't signed by the same certificate")
        #expect(spy.relaunched.isEmpty && spy.terminated == 0)
    }

    @Test func aRequestThePersonDeclinesInstallsNothing() async {
        let spy = InstallSpy()
        spy.confirm = false
        let controller = aboutRequest(spy)
        defer { withExtendedLifetime(controller) {} }
        await settle { false }
        #expect(spy.confirmed.count == 1 && spy.installs.isEmpty && preferences.installStatus == nil)
        #expect(preferences.installRequest == nil)
    }

    @Test(arguments: [("0.5.0", "https://github.com/mblauberg/PureMouse/releases/tag/v0.5.0"),
                      ("0.4.0", "https://github.com/mblauberg/PureMouse/releases/tag/v0.4.0"),
                      ("0.6.0", "https://example.com/mblauberg/PureMouse/releases/tag/v0.6.0"),
                      ("0.6.0", "https://github.com/mblauberg/PureMouse/releases/latest")])
    func aRequestForAnOldVersionOrAnotherPageIsIgnored(_ version: String, _ page: String) async {
        let spy = InstallSpy()
        let controller = aboutRequest(spy, version: version, page: page)
        defer { withExtendedLifetime(controller) {} }
        await settle { false }
        #expect(spy.confirmed.isEmpty && spy.installs.isEmpty && preferences.installRequest == nil)
    }

    @Test func theConfirmationNamesTheVersionAndTheTwoChoices() throws {
        let alert = Alerts.updateConfirmation(UpdateOffer(version: try #require(UpdateCheck.Version("0.6.0")), page: Self.page))
        #expect(alert.messageText == "Update to PureMouse 0.6.0?")
        #expect(alert.buttons.map(\.title) == ["Update and Relaunch", "Cancel"])
        #expect(alert.buttons.first?.keyEquivalent == "\r")
    }
}
