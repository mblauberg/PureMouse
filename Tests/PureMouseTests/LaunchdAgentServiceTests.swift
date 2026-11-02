import Foundation
import PureMouseKit
import Testing
@testable import puremouse

private let appURL = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app")
private let executable = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/MacOS/puremouse")
private let movedExecutable = URL(fileURLWithPath: "/Users/someone/PureMouse.app/Contents/MacOS/puremouse")

/// `LaunchdAgentService` over temporary `agents` and `transient` directories and a scripted
/// `launchctl`: it records the arguments and answers `print` from `loaded`, as launchd would.
private final class Harness: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appending(path: "pm-launchd-\(UUID().uuidString)")
    var agents: URL { root.appending(path: "agents") }
    var transient: URL { root.appending(path: "transient") }
    var calls: [[String]] = []
    /// What launchd says about the job, and what bootstrap, kickstart and bootout do to it.
    var loaded: JobState = .notLoaded
    var failing: Set<String> = []
    var bootoutKeepsJob = false
    let uid = getuid()

    lazy var service = LaunchdAgentService(agents: agents, transient: transient, launchctl: { [unowned self] arguments in
        calls.append(arguments)
        let verb = arguments[0]
        if failing.contains(verb) { return (5, "\(verb) failed") }
        switch verb {
        case "print":
            switch loaded {
            case .notLoaded: return (113, "Could not find service")
            case .loadedIdle: return (0, "gui/501/x = {\n\tstate = not running\n\tlast exit code = 0\n}")
            case .running: return (0, "gui/501/x = {\n\tactive count = 1\n\tstate = running\n\tpid = 123\n}")
            }
        case "bootstrap", "kickstart": loaded = .running
        case "bootout": if !bootoutKeepsJob { loaded = .notLoaded }
        default: break
        }
        return (0, "")
    }, stopPolls: 3, stopPause: 0)

    deinit { try? FileManager.default.removeItem(at: root) }

    func registered(_ job: Job) -> URL { agents.appending(path: "\(job.label).plist") }
    func kept(_ job: Job) -> URL { transient.appending(path: "\(job.label).plist") }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func program(_ url: URL) throws -> String? {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        return (plist?["ProgramArguments"] as? [String])?.first
    }
    /// The launchctl verbs called, in order.
    var verbs: [String] { calls.map { $0[0] } }
}

@Suite struct LaunchdAgentServiceTests {
    // MARK: Starting

    @Test func anUnregisteredJobStartsFromAKeptPlistThatLaunchdDoesNotLoadAtLogin() throws {
        let h = Harness()
        #expect(try h.service.start(.daemon, at: executable))
        #expect(h.calls.last == ["bootstrap", "gui/\(h.uid)", h.kept(.daemon).path])
        #expect(try h.program(h.kept(.daemon)) == executable.path)
        #expect(!h.exists(h.registered(.daemon)))
        #expect(h.service.status(.daemon) == .notRegistered)
    }

    @Test func aRegisteredJobStartsFromItsRegistrationRewrittenForThisBuild() throws {
        let h = Harness()
        try h.service.register(.daemon, at: movedExecutable)
        #expect(try h.service.start(.daemon, at: executable))
        #expect(h.calls.last == ["bootstrap", "gui/\(h.uid)", h.registered(.daemon).path])
        #expect(try h.program(h.registered(.daemon)) == executable.path)
        #expect(!h.exists(h.kept(.daemon)))
        #expect(h.service.status(.daemon) == .enabled)
    }

    @Test func aLoadedJobWithoutAProcessIsKickstartedNotBootstrapped() throws {
        let h = Harness()
        h.loaded = .loadedIdle
        try h.service.register(.menu, at: appURL)
        h.calls = []
        #expect(try h.service.start(.menu, at: appURL))
        #expect(h.calls.last == ["kickstart", "gui/\(h.uid)/\(Job.menu.label)"])
        #expect(!h.verbs.contains("bootstrap"))
        #expect(h.service.state(.menu) == .running)
    }

    @Test func aLoadedUnregisteredJobWithoutAProcessWritesNothing() throws {
        let h = Harness()
        h.loaded = .loadedIdle
        #expect(try h.service.start(.menu, at: appURL))
        #expect(h.verbs == ["print", "kickstart"])
        #expect(!h.exists(h.kept(.menu)))
        #expect(!h.exists(h.registered(.menu)))
    }

    @Test func aRunningJobIsLeftAloneAndItsRegistrationUntouched() throws {
        let h = Harness()
        try h.service.register(.daemon, at: movedExecutable)
        h.loaded = .running
        h.calls = []
        #expect(try !h.service.start(.daemon, at: executable))
        #expect(h.verbs == ["print"])
        #expect(try h.program(h.registered(.daemon)) == movedExecutable.path)
    }

    @Test func aFailedStartNamesTheVerbItFailedAt() throws {
        let h = Harness()
        h.failing = ["bootstrap"]
        #expect(throws: LaunchdAgentService.Failure.bootstrap("bootstrap failed")) { try h.service.start(.daemon, at: executable) }
        h.failing = []
        h.loaded = .loadedIdle
        h.failing = ["kickstart"]
        #expect(throws: LaunchdAgentService.Failure.kickstart("kickstart failed")) { try h.service.start(.daemon, at: executable) }
    }

    // MARK: State

    @Test func stateTellsNotLoadedFromLoadedWithoutAProcessFromRunning() {
        let h = Harness()
        for state in [JobState.notLoaded, .loadedIdle, .running] {
            h.loaded = state
            #expect(h.service.state(.daemon) == state)
        }
        #expect(h.calls.allSatisfy { $0 == ["print", "gui/\(h.uid)/\(Job.daemon.label)"] })
    }

    // MARK: Stopping

    @Test func stopBootsOutAndRemovesTheKeptPlist() throws {
        let h = Harness()
        _ = try h.service.start(.daemon, at: executable)
        #expect(h.exists(h.kept(.daemon)))
        #expect(try h.service.stop(.daemon))
        #expect(h.calls.contains(["bootout", "gui/\(h.uid)/\(Job.daemon.label)"]))
        #expect(!h.exists(h.kept(.daemon)))
        #expect(h.service.state(.daemon) == .notLoaded)
    }

    @Test func stopOfAJobThatIsNotLoadedBootsNothingOutButStillRemovesTheKeptPlist() throws {
        let h = Harness()
        try FileManager.default.createDirectory(at: h.transient, withIntermediateDirectories: true)
        try Data().write(to: h.kept(.menu))
        #expect(try !h.service.stop(.menu))
        #expect(!h.verbs.contains("bootout"))
        #expect(!h.exists(h.kept(.menu)))
    }

    @Test func stopKeepsTheRegistration() throws {
        let h = Harness()
        try h.service.register(.daemon, at: executable)
        h.loaded = .running
        #expect(try h.service.stop(.daemon))
        #expect(h.service.status(.daemon) == .enabled)
    }

    @Test func stopFailsAfterWaitingForAJobThatWillNotLeave() throws {
        let h = Harness()
        _ = try h.service.start(.daemon, at: executable)
        h.bootoutKeepsJob = true
        h.calls = []
        let target = "gui/\(h.uid)/\(Job.daemon.label)"
        #expect(throws: LaunchdAgentService.Failure.stillRunning(target: target, output: "")) { try h.service.stop(.daemon) }
        // One look before bootout, then one per poll.
        #expect(h.verbs == ["print", "bootout", "print", "print", "print"])
        #expect(!h.exists(h.kept(.daemon)))
    }

    // MARK: Registration

    @Test func registrationReplacesThePlistAtomically() throws {
        let h = Harness()
        try h.service.register(.daemon, at: movedExecutable)
        let before = try #require(try FileManager.default.attributesOfItem(atPath: h.registered(.daemon).path)[.systemFileNumber] as? Int)
        try h.service.register(.daemon, at: executable)
        let after = try #require(try FileManager.default.attributesOfItem(atPath: h.registered(.daemon).path)[.systemFileNumber] as? Int)
        // A new file renamed over the old one, not the old one rewritten in place.
        #expect(before != after)
        #expect(try h.program(h.registered(.daemon)) == executable.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.agents.path) == ["\(Job.daemon.label).plist"])
        #expect(h.calls.isEmpty)
    }

    @Test func unregisterRemovesThePlistAndToleratesNone() throws {
        let h = Harness()
        try h.service.unregister(.menu)
        try h.service.register(.menu, at: appURL)
        #expect(h.service.status(.menu) == .enabled)
        try h.service.unregister(.menu)
        #expect(h.service.status(.menu) == .notRegistered)
        #expect(h.calls.isEmpty)
    }

    // MARK: Definitions

    @Test func theDaemonDefinitionIsWhatLaunchdHasAlwaysBeenGiven() {
        let expected: NSDictionary = [
            "Label": "io.github.mblauberg.puremouse",
            "ProgramArguments": [executable.path, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 3,
            "ProcessType": "Interactive",
        ]
        #expect(NSDictionary(dictionary: LaunchdAgentService.definition(.daemon, at: executable)) == expected)
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
        #expect(NSDictionary(dictionary: LaunchdAgentService.definition(.menu, at: appURL)) == expected)
    }

    /// `scripts/lib.zsh` writes the same variable into the menu app's Info.plist (`LSEnvironment`), for
    /// launches by the Finder; the two must not drift apart.
    @Test func theInfoPlistSetsTheSameVariablesAsTheAgent() throws {
        let environment = try #require(LaunchdAgentService.definition(.menu, at: appURL)["EnvironmentVariables"] as? [String: String])
        #expect(!environment.isEmpty)
        let lib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/lib.zsh")
        let script = try String(contentsOf: lib.standardizedFileURL, encoding: .utf8)
        let written = script.components(separatedBy: "<key>LSEnvironment</key><dict>").dropFirst().first?
            .components(separatedBy: "</dict>").first
        #expect(written == environment.sorted { $0.key < $1.key }.map { "<key>\($0.key)</key><string>\($0.value)</string>" }.joined())
    }
}
