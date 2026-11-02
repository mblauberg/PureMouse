import Foundation
import PureMouseKit
import Testing
@testable import puremouse

/// A `LoginService` that keeps state in memory and logs each call, so the policy's ordering and its
/// two independent axes (starts at login, running now) can be asserted. It follows the real
/// service's rules: a job is registered once `register` has run (the one source of truth for
/// `status`), and starting a registered job refreshes its registration first.
private final class FakeLoginService: LoginService {
    var name: String { "fake" }
    /// Where each registered job points.
    var registeredAt: [Job: URL] = [:]
    var states: [Job: JobState] = [:]
    var calls: [String] = []
    /// Where each started job was told to run.
    var startedAt: [Job: URL] = [:]
    /// Runs inside `stop`, for tests that hold a command open.
    var onStop: (() -> Void)?

    var registered: Set<Job> {
        get { Set(registeredAt.keys) }
        set { registeredAt = Dictionary(uniqueKeysWithValues: newValue.map { ($0, URL(fileURLWithPath: "/old")) }) }
    }
    /// The jobs with a process.
    var running: Set<Job> {
        get { Set(states.filter { $0.value == .running }.keys) }
        set { for job in newValue { states[job] = .running } }
    }
    var loaded: Set<Job> { Set(states.filter { $0.value != .notLoaded }.keys) }

    func status(_ job: Job) -> JobStatus { registeredAt[job] == nil ? .notRegistered : .enabled }
    func state(_ job: Job) -> JobState { states[job] ?? .notLoaded }

    func register(_ job: Job, at location: URL) throws {
        calls.append("register \(job)")
        registeredAt[job] = location
    }

    func start(_ job: Job, at location: URL) throws -> Bool {
        calls.append("start \(job)")
        if state(job) == .running { return false }
        if registeredAt[job] != nil { registeredAt[job] = location }
        startedAt[job] = location
        states[job] = .running
        return true
    }

    func unregister(_ job: Job) throws {
        calls.append("unregister \(job)")
        registeredAt[job] = nil
    }

    @discardableResult func stop(_ job: Job) throws -> Bool {
        calls.append("stop \(job)")
        onStop?()
        return states.removeValue(forKey: job) != nil
    }
}

private let appURL = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app")
private let helperURL = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/Helpers/PureMouse Settings.app")
private let installedExecutable = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/MacOS/puremouse")

/// One policy over a fake service and a temporary companion directory.
private final class Rig: @unchecked Sendable {
    let service = FakeLoginService()
    let directory = FileManager.default.temporaryDirectory.appending(path: "pm-login-\(UUID().uuidString)")
    var seeded = 0
    var menuIsCaller = false
    /// Settings requests made, and apps opened with their attempts, in order with the service's calls.
    var requests = 0
    var opened: [(app: URL, attempts: Int)] = []
    /// Whether `open` succeeds.
    var opens = true
    /// Which `open` calls (from 0) reach a live helper that reads the request; the others get a
    /// helper that is exiting, which leaves it in the file.
    var helperReads: Set<Int> = [0]
    private var pending = false
    var pauses: [TimeInterval] = []
    /// Quit PureMouse's stamp; a request clears it, as `SettingsRequest.write` does.
    var quitStamp = false
    /// Quit PureMouse runs while the daemon waits.
    var quitsDuringWait = false
    private let menuApp: URL?
    private let settingsApp: URL?
    private let executable: () throws -> URL
    private let lockTimeout: TimeInterval

    init(menuApp: URL? = appURL, settingsApp: URL? = helperURL, lockTimeout: TimeInterval = 5,
         executable: @escaping () throws -> URL = { installedExecutable }) {
        self.menuApp = menuApp
        self.settingsApp = settingsApp
        self.lockTimeout = lockTimeout
        self.executable = executable
    }

    lazy var item = LoginItem(service: service, host: .init(
        executable: executable, menuApp: menuApp, hiddenMarker: directory.appending(path: Companion.menuHiddenName),
        lockFile: directory.appending(path: "lifecycle.lock"), lockTimeout: lockTimeout,
        calledFromMenu: { [unowned self] _ in menuIsCaller }, seedConfig: { [unowned self] in seeded += 1 },
        settingsApp: settingsApp,
        requestSettings: { [unowned self] in requests += 1; pending = true; quitStamp = false; service.calls.append("request settings") },
        requestPending: { [unowned self] in pending },
        quitStamped: { [unowned self] in quitStamp },
        pause: { [unowned self] in
            pauses.append($0)
            if quitsDuringWait { quitStamp = true }
        },
        open: { [unowned self] app, attempts in
            if helperReads.contains(opened.count) { pending = false }
            opened.append((app, attempts))
            service.calls.append("open \(app.lastPathComponent)")
            return opens
        }))

    deinit { try? FileManager.default.removeItem(at: directory) }

    func hideMenu() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: item.host.hiddenMarker)
    }

    var hidden: Bool { FileManager.default.fileExists(atPath: item.host.hiddenMarker.path) }

    /// The calls since the last `forget`.
    func forget() { service.calls = [] }
}

// MARK: - Ordering

@Suite struct LoginItemTests {
    @Test func registerRegistersTheDaemonBeforeTheMenu() throws {
        let rig = Rig()
        let outcome = try rig.item.register()
        #expect(rig.service.calls == ["stop daemon", "register daemon", "start daemon",
                                      "stop menu", "register menu", "start menu"])
        #expect(outcome == "PureMouse is running and will start at login.")
        #expect(rig.seeded == 1)
        #expect(rig.service.registeredAt == [.daemon: installedExecutable, .menu: appURL])
        #expect(rig.service.startedAt == [.daemon: installedExecutable, .menu: appURL])
        #expect(rig.service.running == [.daemon, .menu])
    }

    @Test func registerRestartsARunningDaemon() throws {
        let rig = Rig()
        rig.service.running = [.daemon]
        #expect(try rig.item.register() == "PureMouse restarted.")
        #expect(rig.service.running == [.daemon, .menu])
    }

    @Test func aHiddenMenuIsNotRegistered() throws {
        let rig = Rig()
        try rig.hideMenu()
        let outcome = try rig.item.register()
        #expect(rig.service.registered == [.daemon])
        #expect(rig.service.running == [.daemon])
        #expect(rig.service.calls == ["stop daemon", "register daemon", "start daemon",
                                      "unregister menu", "stop menu"])
        #expect(outcome == "PureMouse is running and will start at login. The menu bar icon is hidden (`puremouse menu on` shows it).")
    }

    @Test func aBuildWithoutAMenuTouchesOnlyTheDaemon() throws {
        let registering = Rig(menuApp: nil)
        _ = try registering.item.register()
        #expect(registering.service.calls == ["stop daemon", "register daemon", "start daemon"])

        let rig = Rig(menuApp: nil)
        _ = try rig.item.loginOn()
        _ = try rig.item.start()
        _ = try rig.item.loginOff()
        #expect(rig.service.calls == ["register daemon", "start daemon", "unregister daemon", "unregister menu"])
    }

    @Test func unregisterRemovesTheMenuLastAndStopsEachJobRightAfterItsRemoval() throws {
        let rig = Rig()
        _ = try rig.item.register()
        rig.forget()
        try rig.item.unregister()
        #expect(rig.service.calls == ["unregister daemon", "stop daemon", "unregister menu", "stop menu"])
        #expect(rig.service.registered.isEmpty)
        #expect(rig.service.loaded.isEmpty)
    }

    @Test func stopStopsTheDaemonBeforeTheMenuAndKeepsBothRegistered() throws {
        let rig = Rig()
        _ = try rig.item.register()
        rig.forget()
        #expect(try rig.item.stopAll() == "PureMouse stopped; it starts again at login.")
        #expect(rig.service.calls == ["stop daemon", "stop menu"])
        #expect(rig.service.registered == [.daemon, .menu])
        #expect(try rig.item.stopAll() == "PureMouse wasn't running.")
    }

    @Test func stopDoesNotPromiseALoginStartWhenTheJobIsNotRegistered() throws {
        let rig = Rig()
        _ = try rig.item.register()
        _ = try rig.item.loginOff()
        #expect(try rig.item.stopAll() == "PureMouse stopped.")
        _ = try rig.item.start()
        #expect(rig.service.registered.isEmpty)
        #expect(try rig.item.stopAll() == "PureMouse stopped.")
    }

    // MARK: Opened from the Finder

    @Test func finderLaunchRegistersThenOpensTheSettingsHelperOnly() throws {
        let rig = Rig()
        #expect(try rig.item.finderLaunch() == .init(outcome: "PureMouse is running and will start at login.",
                                                     settingsOpened: true))
        #expect(rig.service.calls == ["stop daemon", "register daemon", "start daemon",
                                      "stop menu", "register menu", "start menu",
                                      "request settings", "open PureMouse Settings.app"])
        #expect(rig.opened.map(\.app) == [helperURL])
        #expect(rig.opened.map(\.attempts) == [2])
    }

    @Test func finderLaunchOpensSettingsWithTheMenuIconHidden() throws {
        let rig = Rig()
        try rig.hideMenu()
        #expect(try rig.item.finderLaunch().settingsOpened)
        #expect(rig.service.registered == [.daemon])
        #expect(rig.opened.map(\.app) == [helperURL])
        #expect(rig.hidden)
    }

    @Test func aMissingHelperLeavesTheAlertAndRegistrationDone() throws {
        let rig = Rig(settingsApp: nil)
        let launch = try rig.item.finderLaunch()
        #expect(!launch.settingsOpened)
        #expect(launch.outcome == "PureMouse is running and will start at login.")
        #expect(rig.service.registered == [.daemon, .menu])
        #expect(rig.service.running == [.daemon, .menu])
        #expect(rig.requests == 0)
        #expect(rig.opened.isEmpty)
    }

    @Test func aHelperThatWillNotOpenLeavesTheAlertAndRegistrationDone() throws {
        let rig = Rig()
        rig.opens = false
        #expect(try rig.item.finderLaunch().settingsOpened == false)
        #expect(rig.service.registered == [.daemon, .menu])
        #expect(rig.requests == 1)
    }

    /// `open` exits 0 with the instance that is quitting, which never reads the request.
    @Test func aHelperThatDoesNotReadTheRequestIsOpenedAgainWithAFreshOne() throws {
        let rig = Rig()
        rig.helperReads = [1]
        #expect(rig.item.openSettings())
        #expect(rig.opened.map(\.app) == [helperURL, helperURL])
        #expect(rig.requests == 2)
        #expect(rig.pauses.reduce(0, +) >= LoginItem.settingsWait.total)
    }

    /// Writing again would clear the stamp, and the second open would bring Settings back.
    @Test func aQuitDuringTheWaitIsNotUndoneByTheSecondOpen() {
        let rig = Rig()
        rig.helperReads = []
        rig.quitsDuringWait = true
        #expect(rig.item.openSettings())
        #expect(rig.opened.count == 1)
        #expect(rig.requests == 1)
        #expect(rig.quitStamp)
    }

    @Test func aHelperThatReadsTheRequestIsOpenedOnce() {
        let rig = Rig()
        rig.helperReads = [0]
        #expect(rig.item.openSettings())
        #expect(rig.opened.count == 1)
        #expect(rig.pauses.isEmpty)
    }

    @Test func nothingOpensWhenRegisteringFails() {
        let rig = Rig(executable: { throw LoginItem.Failure.translocated })
        #expect(throws: LoginItem.Failure.translocated) { try rig.item.finderLaunch() }
        #expect(rig.requests == 0)
        #expect(rig.opened.isEmpty)
    }

    // MARK: The menu app as the caller

    @Test func registerFromTheMenuRewritesALoadedMenuJobWithoutRestartingIt() throws {
        let rig = Rig()
        rig.menuIsCaller = true
        rig.service.running = [.menu]
        _ = try rig.item.register()
        #expect(rig.service.calls == ["stop daemon", "register daemon", "start daemon", "register menu"])
        #expect(rig.service.running == [.daemon, .menu])
    }

    @Test func registerFromTheMenuStartsAMenuJobThatIsNotLoaded() throws {
        let rig = Rig()
        rig.menuIsCaller = true
        _ = try rig.item.register()
        #expect(rig.service.calls.suffix(3) == ["stop menu", "register menu", "start menu"])
    }

    @Test func menuOnFromTheMenuLeavesALoadedMenuJobRunning() throws {
        let rig = Rig()
        rig.menuIsCaller = true
        rig.service.running = [.menu]
        #expect(try rig.item.showMenu(true) == "The menu bar icon is shown.")
        #expect(rig.service.calls == ["register menu"])
    }

    // MARK: menu on|off

    @Test func menuOffIsRememberedAndRemovesOnlyTheMenu() throws {
        let rig = Rig()
        _ = try rig.item.register()
        rig.forget()
        #expect(try rig.item.showMenu(false) == "The menu bar icon is hidden; `puremouse menu on` shows it again.")
        #expect(rig.hidden)
        #expect(rig.service.calls == ["unregister menu", "stop menu"])
        #expect(rig.service.registered == [.daemon])
        #expect(rig.service.running == [.daemon])

        rig.forget()
        #expect(try rig.item.showMenu(true) == "The menu bar icon is shown.")
        #expect(!rig.hidden)
        #expect(rig.service.calls == ["stop menu", "register menu", "start menu"])
    }

    @Test func menuOnNeedsAMenuApp() throws {
        let rig = Rig(menuApp: nil)
        #expect(throws: LoginItem.Failure.noMenuApp) { try rig.item.showMenu(true) }
        #expect(rig.service.calls.isEmpty)
    }

    // MARK: Not an installed app

    @Test func nothingChangesWhenThisIsNotAnInstalledApp() {
        let rig = Rig(executable: { throw LoginItem.Failure.notInBundle })
        #expect(throws: LoginItem.Failure.notInBundle) { try rig.item.register() }
        #expect(throws: LoginItem.Failure.notInBundle) { try rig.item.unregister() }
        #expect(throws: LoginItem.Failure.notInBundle) { try rig.item.stopAll() }
        #expect(throws: LoginItem.Failure.notInBundle) { try rig.item.start() }
        #expect(throws: LoginItem.Failure.notInBundle) { try rig.item.loginOn() }
        #expect(throws: LoginItem.Failure.notInBundle) { try rig.item.loginOff() }
        #expect(throws: LoginItem.Failure.notInBundle) { try rig.item.showMenu(false) }
        #expect(throws: LoginItem.Failure.notInBundle) { try rig.item.showMenu(true) }
        #expect(rig.service.calls.isEmpty)
        #expect(rig.seeded == 0)
        #expect(!rig.hidden)
        #expect(!FileManager.default.fileExists(atPath: rig.item.host.lockFile.path))
    }

    // MARK: The two axes

    /// (starts at login, running now) for the daemon and the menu.
    private func axes(_ rig: Rig) -> [Bool] {
        [rig.service.registered.contains(.daemon), rig.service.running.contains(.daemon),
         rig.service.registered.contains(.menu), rig.service.running.contains(.menu)]
    }

    @Test(arguments: [false, true]) func eachCommandChangesOnlyItsOwnAxis(hidden: Bool) throws {
        let rig = Rig()
        if hidden { try rig.hideMenu() }
        let menuShown = !hidden

        // start: running on, login unchanged (off).
        #expect(try rig.item.start() == "PureMouse started.")
        #expect(axes(rig) == [false, true, false, menuShown])
        #expect(try rig.item.start() == "PureMouse is already running.")

        // login on: login on, running unchanged, nothing loaded or stopped.
        rig.forget()
        #expect(try rig.item.loginOn() == "PureMouse will start at login.")
        #expect(axes(rig) == [true, true, menuShown, menuShown])
        #expect(!rig.service.calls.contains { $0.hasPrefix("start") || $0.hasPrefix("stop") })

        // stop: running off, login unchanged (on).
        _ = try rig.item.stopAll()
        #expect(axes(rig) == [true, false, menuShown, false])

        // start: running on, login unchanged (on).
        _ = try rig.item.start()
        #expect(axes(rig) == [true, true, menuShown, menuShown])

        // login off: login off, running unchanged, nothing stopped.
        rig.forget()
        #expect(try rig.item.loginOff()
            == "PureMouse won't start at login; it keeps running until you quit it (`puremouse stop`).")
        #expect(axes(rig) == [false, true, false, menuShown])
        #expect(rig.service.calls == ["unregister daemon", "unregister menu"])
        _ = try rig.item.stopAll()
        #expect(try rig.item.loginOff() == "PureMouse won't start at login.")
        #expect(axes(rig) == [false, false, false, false])
    }

    // MARK: start from each state

    @Test(arguments: [JobState.notLoaded, .loadedIdle, .running])
    func startRunsEveryJobThatHasNoProcess(initial: JobState) throws {
        let rig = Rig()
        rig.service.states = [.daemon: initial, .menu: initial]
        rig.service.registered = [.daemon]
        #expect(try rig.item.start() == (initial == .running ? "PureMouse is already running." : "PureMouse started."))
        #expect(rig.service.running == [.daemon, .menu])
        #expect(rig.service.registered == [.daemon])
        #expect(rig.service.startedAt.isEmpty == (initial == .running))
    }

    @Test func startOnlyStartsTheJobThatHasNoProcess() throws {
        let rig = Rig()
        rig.service.states = [.daemon: .running, .menu: .loadedIdle]
        #expect(try rig.item.start() == "PureMouse started.")
        #expect(Set(rig.service.startedAt.keys) == [.menu])
    }

    @Test func startBringsARegistrationUpToDateButNotARunningJobs() throws {
        let rig = Rig()
        rig.service.registered = [.daemon, .menu]
        rig.service.states = [.menu: .running]
        _ = try rig.item.start()
        #expect(rig.service.registeredAt[.daemon] == installedExecutable)
        #expect(rig.service.registeredAt[.menu] == URL(fileURLWithPath: "/old"))
    }

    // MARK: Status

    @Test func loginStatusReportsEachJobAndTheHiddenMenu() throws {
        let rig = Rig()
        #expect(rig.item.loginStatus() == LoginStatus(service: "fake", daemon: .notRegistered, menu: .notRegistered, hidden: false))
        _ = try rig.item.loginOn()
        #expect(rig.item.loginStatus() == LoginStatus(service: "fake", daemon: .enabled, menu: .enabled, hidden: false))
        _ = try rig.item.showMenu(false)
        #expect(rig.item.loginStatus() == LoginStatus(service: "fake", daemon: .enabled, menu: .notRegistered, hidden: true))
        let bare = Rig(menuApp: nil)
        #expect(bare.item.loginStatus().menu == .notFound)
    }

    // MARK: Serialised commands

    @Test func overlappingCommandsRunOneAfterTheOther() throws {
        let rig = Rig()
        rig.service.running = [.daemon, .menu]
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var held = false
        rig.service.onStop = {
            guard !held else { return }
            held = true
            entered.signal()
            release.wait()
        }
        let done = DispatchGroup()
        DispatchQueue.global().async(group: done) { _ = try? rig.item.stopAll() }
        entered.wait()
        DispatchQueue.global().async(group: done) { _ = try? rig.item.start() }
        // The second command is waiting for the first, so it has not touched the service.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(rig.service.calls == ["stop daemon"])
        release.signal()
        done.wait()
        #expect(rig.service.calls == ["stop daemon", "stop menu", "start daemon", "start menu"])
        #expect(rig.service.running == [.daemon, .menu])
    }

    @Test func aCommandGivesUpWhenAnotherHoldsTheLock() throws {
        let rig = Rig(lockTimeout: 0.2)
        try FileManager.default.createDirectory(at: rig.directory, withIntermediateDirectories: true)
        let fd = open(rig.item.host.lockFile.path, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(throws: FileLock.Failed.self) { try rig.item.start() }
        #expect(throws: FileLock.Failed.self) { try rig.item.stopAll() }
        #expect(rig.service.calls.isEmpty)
        // login-status only reads.
        #expect(rig.item.loginStatus().service == "fake")
    }

    // MARK: What the user is told

    @Test func aCopyOutsideApplicationsIsToldToMoveIt() {
        let alert = LoginItem.startFailureAlert(LoginItem.Failure.translocated)
        #expect(alert.title == "PureMouse needs to be in your Applications folder.")
        #expect(alert.body == "Move it there, then open it again.")
    }

    @Test func aCopyThatIsNotInstalledIsToldToInstallIt() {
        let alert = LoginItem.startFailureAlert(LoginItem.Failure.notInBundle)
        #expect(alert.title == "This copy of PureMouse can't open at login.")
        #expect(alert.body == "Install it from the disk image, then open it again.")
    }

    @Test func anyOtherFailureGetsTheNextStepNotTheRawError() {
        struct Raw: Error, CustomStringConvertible { var description: String { "Bootstrap failed: 5" } }
        let alert = LoginItem.startFailureAlert(Raw())
        #expect(alert.title == "PureMouse couldn't start.")
        #expect(alert.body == "Try again. If it keeps happening, restart your Mac.")
    }

    @Test func theFinderAlertHasNoPathsAndAsksForTheTwoPermissions() {
        let alert = LoginItem.runningAlert
        #expect(alert.title == "PureMouse is running.")
        #expect(alert.body == "It will open at login. macOS will ask you to allow Accessibility and Input Monitoring. "
            + "Choose Allow for each, or turn them on in System Settings > Privacy & Security.")
        #expect(!alert.body.contains("/"))
    }

    @Test func aCommandLineFailureNamesTheProgram() {
        #expect(CLIError.line("can't register", LoginItem.Failure.translocated)
            == "puremouse: can't register: PureMouse needs to be in your Applications folder. Move it there, then open it again.")
        #expect(CLIError.line("unknown or device-only action", "explode")
            == "puremouse: unknown or device-only action: explode")
    }
}
