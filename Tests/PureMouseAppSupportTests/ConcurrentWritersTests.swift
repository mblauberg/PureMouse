import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

/// Every config write is one read-merge-replace under `config.json.lock`, and every control write
/// one under `control.json.lock` that changes only the writer's own fields, so writers in other
/// processes (the menu, the Settings helper, a second copy) never drop each other's changes.
struct ConcurrentWritersTests {
    /// The test-only second writer, built beside this test bundle.
    static func probe() throws -> URL {
        let products = Bundle(for: ManualClock.self).bundleURL.deletingLastPathComponent()
        let url = products.appending(path: "ConfigWriterProbe")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "ConfigWriterProbe not built at \(url.path)")
        return url
    }

    static func launch(_ arguments: [String]) throws -> (process: Process, errors: Pipe) {
        let process = Process()
        process.executableURL = try probe()
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        return (process, errors)
    }

    static func finish(_ run: (process: Process, errors: Pipe)) -> String {
        run.process.waitUntilExit()
        let errors = String(decoding: run.errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return "exit \(run.process.terminationStatus) \(errors)"
    }

    /// Holds the config's lock through its own descriptor, as another writer would.
    static func hold(_ lock: URL) throws -> Int32 {
        let fd = open(lock.path, O_RDWR | O_CREAT, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX) == 0)
        return fd
    }

    @Test func aSaveWaitsWhileAnotherDescriptorHoldsTheLock() async throws {
        let sandbox = try Sandbox()
        try sandbox.write(#"{"dpi": 800}"#)
        let fd = try Self.hold(ConfigFile(url: sandbox.config).lockURL)
        let url = sandbox.config
        let save = Task.detached {
            try ConfigFile(url: url).save([ConfigTree.Change(path: ["dpi"], value: 1200)]).tree.int(["dpi"])
        }
        try await Task.sleep(for: .milliseconds(300))
        // Nothing is written without the lock.
        #expect(try sandbox.read() == #"{"dpi": 800}"#)
        flock(fd, LOCK_UN)
        close(fd)
        #expect(try await save.value == 1200)
        #expect(try sandbox.tree().int(["dpi"]) == 1200)
    }

    @Test func aSaveInAnotherProcessWaitsForTheLock() async throws {
        let sandbox = try Sandbox()
        try sandbox.write(#"{"dpi": 800}"#)
        let fd = try Self.hold(ConfigFile(url: sandbox.config).lockURL)
        let run = try Self.launch([sandbox.directory.path, "save", "late", "1"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(run.process.isRunning)
        #expect(try sandbox.read() == #"{"dpi": 800}"#)
        flock(fd, LOCK_UN)
        close(fd)
        #expect(Self.finish(run) == "exit 0 ")
        let tree = try sandbox.tree()
        #expect(tree.int(["late", "k0"]) == 0)
        #expect(tree.int(["dpi"]) == 800)
    }

    /// Two processes save different keys while one of them resets the file once, and two more
    /// write `control.json` as the menu and as Settings.
    @Test func interleavedWritersLoseNothing() throws {
        let sandbox = try Sandbox()
        try sandbox.write(#"{"dpi": 800}"#)
        let count = 60
        let dir = sandbox.directory.path
        let runs = try [
            Self.launch([dir, "save", "a", "\(count)"]),
            Self.launch([dir, "save", "b", "\(count)", "\(count / 2)"]),
            Self.launch([dir, "control", "menu", "40"]),
            Self.launch([dir, "control", "settings", "40"]),
        ]
        for run in runs { #expect(Self.finish(run) == "exit 0 ") }

        let file = try sandbox.tree()  // the file parses
        let backup = try sandbox.tree(sandbox.backup)
        for prefix in ["a", "b"] {
            for index in 0..<count {
                let path = [prefix, "k\(index)"]
                #expect(file.int(path) == index || backup.int(path) == index, "\(prefix).k\(index) was lost")
            }
        }
        // The reset kept what it replaced.
        #expect(backup.int(["dpi"]) == 800)
        // Each role's last word survives the other's writes.
        let control = try #require(sandbox.control())
        #expect(control.paused)
        #expect(control.capture == Control.Capture(token: 77))
    }
}

@MainActor
private func link(_ sandbox: Sandbox, owns: DaemonLink.ControlFields, tokens: [Int] = [101, 102]) -> DaemonLink {
    var tokens = tokens
    let link = DaemonLink(locations: sandbox.locations, owns: owns, isAlive: { $0 == 4242 },
                          newToken: { tokens.removeFirst() }, ring: {})
    link.reloadStatus()
    return link
}

@MainActor @Test func theMenuWritingPausedKeepsSettingsCapture() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus())
    try Companion.write(Control(paused: false, capture: .init(token: 5), useConfiguredDPI: 9), to: sandbox.locations.control)
    let menu = link(sandbox, owns: .menu)
    menu.setPaused(true)
    #expect(sandbox.control() == Control(paused: true, capture: .init(token: 5), useConfiguredDPI: 9))
}

@MainActor @Test func settingsCancellingACaptureKeepsThePause() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus(paused: false))
    try Companion.write(Control(paused: true, capture: nil, useConfiguredDPI: 9), to: sandbox.locations.control)
    let settings = link(sandbox, owns: .settings)
    settings.capture = .init(token: 3)
    settings.writeControl()
    #expect(sandbox.control() == Control(paused: true, capture: .init(token: 3), useConfiguredDPI: 9))
    settings.capture = nil
    settings.writeControl()
    #expect(sandbox.control() == Control(paused: true, capture: nil, useConfiguredDPI: 9))
}

@MainActor @Test func aLaterWriteKeepsAnotherWritersNewerDPIToken() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus())
    let menu = link(sandbox, owns: .menu, tokens: [101])
    let settings = link(sandbox, owns: .settings, tokens: [201])
    menu.requestConfiguredDPI()
    settings.requestConfiguredDPI()
    menu.setPaused(true)
    #expect(sandbox.control()?.useConfiguredDPI == 201)
}

@MainActor @Test func aRestartedDaemonIsNotSentAnOldDPIToken() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus())
    let menu = link(sandbox, owns: .all)
    menu.requestConfiguredDPI()
    #expect(sandbox.control()?.useConfiguredDPI == 101)
    // The daemon deletes control.json at start.
    try FileManager.default.removeItem(at: sandbox.locations.control)
    menu.setPaused(true)
    #expect(sandbox.control() == Control(paused: true, capture: nil, useConfiguredDPI: nil))
}
