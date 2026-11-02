import Foundation
import PureMouseAppSupport
import Testing
@testable import PureMouseMenu

/// `SettingsLauncher` against a stand-in LaunchServices: opens answer when the test says so, and
/// delayed work runs when the test says so.
@MainActor
final class FakeSystem {
    final class Helper: RunningHelper {
        var isAlive: Bool
        var quitCount = 0
        init(alive: Bool) { isAlive = alive }
        func quit() {
            quitCount += 1
            isAlive = false
        }
    }

    let app = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/Helpers/PureMouse Settings.app")
    var posts: [SettingsPane?] = []
    var opens: [@MainActor ((any RunningHelper)?, (any Error)?) -> Void] = []
    var running: [Helper] = []
    var delayed: [(TimeInterval, @MainActor () -> Void)] = []
    var alerts: [String] = []

    var system: SettingsLauncher.System {
        SettingsLauncher.System(
            find: { [app] in .success(.app(app)) },
            post: { [unowned self] in posts.append($0) },
            open: { [unowned self] _, completion in opens.append(completion) },
            running: { [unowned self] _ in running },
            after: { [unowned self] delay, work in delayed.append((delay, work)) },
            alert: { [unowned self] title, _ in alerts.append(title) })
    }

    /// Answers the oldest open still waiting.
    func answer(_ helper: Helper?) {
        guard !opens.isEmpty else { Issue.record("no open is waiting"); return }
        opens.removeFirst()(helper, nil)
    }

    func runDelayed() {
        let work = delayed
        delayed = []
        work.forEach { $0.1() }
    }
}

@MainActor
struct SettingsLauncherTests {
    @Test func anOpenThatFindsOnlyAQuittingHelperIsTriedAgain() {
        let fake = FakeSystem()
        let launcher = SettingsLauncher(system: fake.system)
        var done = 0
        launcher.open(pane: .pointer) { done += 1 }
        // The copy that just closed its window is still listed, and is what LaunchServices returns.
        let dead = FakeSystem.Helper(alive: false)
        fake.running = [dead]
        fake.answer(dead)
        #expect(done == 0)
        #expect(fake.delayed.map(\.0) == [SettingsLauncher.retryDelay])
        fake.runDelayed()
        #expect(fake.opens.count == 1, "opened again")
        #expect(fake.posts == [.pointer, .pointer], "the pane is asked for again")
        let live = FakeSystem.Helper(alive: true)
        fake.running = [live]
        fake.answer(live)
        #expect(done == 1)
        #expect(fake.alerts.isEmpty)
    }

    @Test func aLiveHelperIsOpenedOnce() {
        let fake = FakeSystem()
        let launcher = SettingsLauncher(system: fake.system)
        var done = 0
        launcher.open { done += 1 }
        let live = FakeSystem.Helper(alive: true)
        fake.running = [live]
        fake.answer(live)
        #expect(done == 1)
        #expect(fake.delayed.isEmpty && fake.opens.isEmpty)
    }

    @Test func aHelperThatOpensAfterQuitBeganIsQuitAndQuitWaitsForIt() {
        let fake = FakeSystem()
        let launcher = SettingsLauncher(system: fake.system)
        launcher.open()
        var quit = 0
        launcher.quit { quit += 1 }
        #expect(quit == 0, "waits for the open under way")
        let late = FakeSystem.Helper(alive: true)
        fake.running = [late]
        fake.answer(late)
        #expect(late.quitCount >= 1)
        #expect(quit == 1)
        // The bound on the wait fires later and changes nothing.
        fake.runDelayed()
        #expect(quit == 1)
        // Nothing opens once quitting.
        launcher.open()
        #expect(fake.opens.isEmpty)
    }

    @Test func quitDuringARetryWaitOpensNothingMore() {
        let fake = FakeSystem()
        let launcher = SettingsLauncher(system: fake.system)
        launcher.open()
        fake.answer(FakeSystem.Helper(alive: false))
        var quit = 0
        launcher.quit { quit += 1 }
        #expect(quit == 0)
        fake.runDelayed() // the retry, then the quit's bound
        #expect(fake.opens.isEmpty)
        #expect(quit == 1)
    }

    @Test func quitWithNothingOpeningGoesOnAtOnce() {
        let fake = FakeSystem()
        let live = FakeSystem.Helper(alive: true)
        fake.running = [live]
        let launcher = SettingsLauncher(system: fake.system)
        var quit = 0
        launcher.quit { quit += 1 }
        #expect(quit == 1)
        #expect(live.quitCount == 1)
    }
}
