import Foundation
import PureMouseKit
import Testing
@testable import puremouse

/// A `LoginService` that keeps state in memory and logs each call, so the policy's ordering and its
/// two independent axes (starts at login, running now) can be asserted.
private final class FakeLoginService: LoginService {
    var name: String { "fake" }
    var registered: Set<Job> = []
    var loaded: Set<Job> = []
    var calls: [String] = []
    var definitions: [Job: [String: Any]] = [:]
    var loadedDefinitions: [Job: [String: Any]] = [:]

    func status(_ job: Job) -> JobStatus { registered.contains(job) ? .enabled : .notRegistered }
    func isLoaded(_ job: Job) -> Bool { loaded.contains(job) }

    func register(_ job: Job, _ definition: [String: Any]) throws {
        calls.append("register \(job)")
        registered.insert(job)
        definitions[job] = definition
    }

    func load(_ job: Job, _ definition: [String: Any]) throws {
        calls.append("load \(job)")
        loaded.insert(job)
        loadedDefinitions[job] = definition
    }

    func unregister(_ job: Job) throws {
        calls.append("unregister \(job)")
        registered.remove(job)
    }

    @discardableResult func stop(_ job: Job) throws -> Bool {
        calls.append("stop \(job)")
        return loaded.remove(job) != nil
    }
}

private let appURL = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app")
private let installedExecutable = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/MacOS/puremouse")

/// One policy over a fake service and a temporary companion directory.
private final class Rig {
    let service = FakeLoginService()
    let directory = FileManager.default.temporaryDirectory.appending(path: "pm-login-\(UUID().uuidString)")
    var seeded = 0
    var menuIsCaller = false
    private let menuApp: URL?
    private let executable: () throws -> URL

    init(menuApp: URL? = appURL, executable: @escaping () throws -> URL = { installedExecutable }) {
        self.menuApp = menuApp
        self.executable = executable
    }

    lazy var item = LoginItem(service: service, host: .init(
        executable: executable, menuApp: menuApp, hiddenMarker: directory.appending(path: "menu-hidden"),
        calledFromMenu: { [unowned self] _ in menuIsCaller }, seedConfig: { [unowned self] in seeded += 1 }))

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
        #expect(rig.service.calls == ["stop daemon", "register daemon", "load daemon",
                                      "stop menu", "register menu", "load menu"])
        #expect(outcome == "PureMouse is running and will start at login.")
        #expect(rig.seeded == 1)
        #expect(rig.service.registered == [.daemon, .menu])
        #expect(rig.service.loaded == [.daemon, .menu])
    }

    @Test func registerRestartsARunningDaemon() throws {
        let rig = Rig()
        rig.service.loaded = [.daemon]
        #expect(try rig.item.register() == "PureMouse restarted.")
        #expect(rig.service.loaded == [.daemon, .menu])
    }

    @Test func aHiddenMenuIsNotRegistered() throws {
        let rig = Rig()
        try rig.hideMenu()
        let outcome = try rig.item.register()
        #expect(rig.service.registered == [.daemon])
        #expect(rig.service.loaded == [.daemon])
        #expect(rig.service.calls == ["stop daemon", "register daemon", "load daemon",
                                      "unregister menu", "stop menu"])
        #expect(outcome == "PureMouse is running and will start at login. The menu bar icon is hidden (`puremouse menu on` shows it).")
    }

    @Test func aBuildWithoutAMenuTouchesOnlyTheDaemon() throws {
        let rig = Rig(menuApp: nil)
        _ = try rig.item.register()
        #expect(rig.service.calls == ["stop daemon", "register daemon", "load daemon"])
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
        #expect(try rig.item.stopAll() == "PureMouse was not running.")
    }

    @Test func stopDoesNotPromiseALoginStartWhenTheJobIsNotRegistered() throws {
        let rig = Rig()
        _ = try rig.item.register()
        _ = try rig.item.loginOff()
        #expect(try rig.item.stopAll() == "PureMouse stopped.")
        #expect(try rig.item.stopAll() == "PureMouse was not running.")
        _ = try rig.item.start()
        #expect(rig.service.registered.isEmpty)
        #expect(try rig.item.stopAll() == "PureMouse stopped.")
    }

    // MARK: The menu app as the caller

    @Test func registerFromTheMenuRewritesALoadedMenuJobWithoutRestartingIt() throws {
        let rig = Rig()
        rig.menuIsCaller = true
        rig.service.loaded = [.menu]
        _ = try rig.item.register()
        #expect(rig.service.calls == ["stop daemon", "register daemon", "load daemon", "register menu"])
        #expect(rig.service.loaded == [.daemon, .menu])
    }

    @Test func registerFromTheMenuStartsAMenuJobThatIsNotLoaded() throws {
        let rig = Rig()
        rig.menuIsCaller = true
        _ = try rig.item.register()
        #expect(rig.service.calls.suffix(3) == ["stop menu", "register menu", "load menu"])
    }

    @Test func menuOnFromTheMenuLeavesALoadedMenuJobRunning() throws {
        let rig = Rig()
        rig.menuIsCaller = true
        rig.service.loaded = [.menu]
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
        #expect(rig.service.loaded == [.daemon])

        rig.forget()
        #expect(try rig.item.showMenu(true) == "The menu bar icon is shown.")
        #expect(!rig.hidden)
        #expect(rig.service.calls == ["stop menu", "register menu", "load menu"])
    }

    @Test func menuOnNeedsAMenuApp() throws {
        let rig = Rig(menuApp: nil)
        #expect(throws: LoginItem.Failure.noMenuApp) { try rig.item.showMenu(true) }
        #expect(rig.service.calls.isEmpty)
    }

    @Test func aBuildWithoutAMenuStartsAndRegistersOnlyTheDaemon() throws {
        let rig = Rig(menuApp: nil)
        _ = try rig.item.loginOn()
        _ = try rig.item.start()
        _ = try rig.item.loginOff()
        #expect(rig.service.calls == ["register daemon", "load daemon", "unregister daemon", "unregister menu"])
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
    }

    // MARK: The two axes

    /// (starts at login, running now) for the daemon and the menu.
    private func axes(_ rig: Rig) -> [Bool] {
        [rig.service.registered.contains(.daemon), rig.service.loaded.contains(.daemon),
         rig.service.registered.contains(.menu), rig.service.loaded.contains(.menu)]
    }

    @Test(arguments: [false, true]) func eachCommandChangesOnlyItsOwnAxis(hidden: Bool) throws {
        let rig = Rig()
        if hidden { try rig.hideMenu() }
        let menuShown = !hidden

        // start: running on, login unchanged (off).
        #expect(try rig.item.start() == "PureMouse started.")
        #expect(axes(rig) == [false, true, false, menuShown])
        #expect(try rig.item.start() == "PureMouse is already running.")

        // login on: login on, running unchanged.
        #expect(try rig.item.loginOn() == "PureMouse will start at login.")
        #expect(axes(rig) == [true, true, menuShown, menuShown])

        // stop: running off, login unchanged (on).
        _ = try rig.item.stopAll()
        #expect(axes(rig) == [true, false, menuShown, false])

        // start: running on, login unchanged (on).
        _ = try rig.item.start()
        #expect(axes(rig) == [true, true, menuShown, menuShown])

        // login off: login off, running unchanged.
        #expect(try rig.item.loginOff()
            == "PureMouse will not start at login; it keeps running until you quit it (`puremouse stop`).")
        #expect(axes(rig) == [false, true, false, menuShown])
        _ = try rig.item.stopAll()
        #expect(try rig.item.loginOff() == "PureMouse will not start at login.")
        #expect(axes(rig) == [false, false, false, false])
    }

    @Test func loginOnAndOffNeverLoadOrStopAnything() throws {
        let rig = Rig()
        _ = try rig.item.loginOn()
        _ = try rig.item.loginOff()
        #expect(rig.service.calls == ["register daemon", "register menu", "unregister daemon", "unregister menu"])
        #expect(rig.seeded == 1)
    }

    @Test func startLeavesRunningJobsAndRegistrationsAlone() throws {
        let rig = Rig()
        rig.service.loaded = [.menu]
        rig.service.registered = [.daemon]
        _ = try rig.item.start()
        #expect(rig.service.calls == ["load daemon"])
        #expect(rig.service.registered == [.daemon])
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

    // MARK: Definitions

    @Test func theDaemonDefinitionIsWhatLaunchdHasAlwaysBeenGiven() {
        let expected: NSDictionary = [
            "Label": "io.github.mblauberg.puremouse",
            "ProgramArguments": [installedExecutable.path, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 3,
            "ProcessType": "Interactive",
        ]
        #expect(NSDictionary(dictionary: LoginItem.daemonDefinition(executable: installedExecutable)) == expected)
    }

    @Test func theMenuDefinitionAddsOnlyTheAllocatorSetting() {
        let expected: NSDictionary = [
            "Label": "io.github.mblauberg.puremouse.menu",
            "ProgramArguments": [appURL.appending(path: "Contents/MacOS/PureMouseMenu").path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "EnvironmentVariables": ["MallocSpaceEfficient": "1"],
        ]
        #expect(NSDictionary(dictionary: LoginItem.menuDefinition(app: appURL)) == expected)
    }

    @Test func startLoadsTheDefinitionsSoAnUnregisteredJobCanRun() throws {
        let rig = Rig()
        _ = try rig.item.start()
        #expect(NSDictionary(dictionary: try #require(rig.service.loadedDefinitions[.daemon]))
            == NSDictionary(dictionary: LoginItem.daemonDefinition(executable: installedExecutable)))
        #expect(NSDictionary(dictionary: try #require(rig.service.loadedDefinitions[.menu]))
            == NSDictionary(dictionary: LoginItem.menuDefinition(app: appURL)))
    }

    @Test func theServiceReceivesTheDefinitions() throws {
        let rig = Rig()
        _ = try rig.item.register()
        #expect(NSDictionary(dictionary: try #require(rig.service.definitions[.daemon]))
            == NSDictionary(dictionary: LoginItem.daemonDefinition(executable: installedExecutable)))
        #expect(NSDictionary(dictionary: try #require(rig.service.definitions[.menu]))
            == NSDictionary(dictionary: LoginItem.menuDefinition(app: appURL)))
    }

    /// `scripts/lib.zsh` writes the same variable into the menu app's Info.plist (`LSEnvironment`), for
    /// launches by the Finder; the two must not drift apart.
    @Test func theInfoPlistSetsTheSameVariablesAsTheAgent() throws {
        let environment = try #require(LoginItem.menuDefinition(app: appURL)["EnvironmentVariables"] as? [String: String])
        #expect(!environment.isEmpty)
        let lib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/lib.zsh")
        let script = try String(contentsOf: lib.standardizedFileURL, encoding: .utf8)
        let written = script.components(separatedBy: "<key>LSEnvironment</key><dict>").dropFirst().first?
            .components(separatedBy: "</dict>").first
        #expect(written == environment.sorted { $0.key < $1.key }.map { "<key>\($0.key)</key><string>\($0.value)</string>" }.joined())
    }
}
