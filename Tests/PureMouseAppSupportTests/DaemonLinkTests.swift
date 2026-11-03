import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

@MainActor
private func link(_ sandbox: Sandbox, alive: Set<Int32> = [4242], tokens: [Int] = [101, 102, 103]) -> DaemonLink {
    var tokens = tokens
    return DaemonLink(locations: sandbox.locations, isAlive: { alive.contains($0) },
                      newToken: { tokens.removeFirst() }, ring: {})
}

@MainActor @Test func noStatusFileMeansOff() throws {
    let sandbox = try Sandbox()
    let daemon = link(sandbox)
    daemon.reloadStatus()
    #expect(daemon.status == nil && !daemon.daemonRunning && !daemon.statusTooNew)
}

@MainActor @Test func aRunningStatusNeedsALiveProcess() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus(pid: 4242))
    #expect({ let d = link(sandbox); d.reloadStatus(); return d.daemonRunning }())
    // `running` alone survives a crash.
    let crashed = link(sandbox, alive: [])
    crashed.reloadStatus()
    #expect(crashed.status != nil && !crashed.daemonRunning)
    // The final status written while shutting down.
    try sandbox.writeStatus(daemonStatus(pid: 4242, running: false))
    let stopped = link(sandbox)
    stopped.reloadStatus()
    #expect(!stopped.daemonRunning)
}

@MainActor @Test func aNewerSchemaIsTooNewWhetherOrNotItDecodes() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus(schema: Status.currentSchema + 1))
    let daemon = link(sandbox)
    daemon.reloadStatus()
    #expect(daemon.statusTooNew)
    try sandbox.write(#"{"schema": 99, "something": "else"}"#, to: sandbox.locations.status)
    daemon.reloadStatus()
    #expect(daemon.statusTooNew && daemon.status == nil)
    try sandbox.write("not json", to: sandbox.locations.status)
    daemon.reloadStatus()
    #expect(!daemon.statusTooNew && daemon.status == nil)
}

@MainActor @Test func aPauseShowsAtOnceAndHoldsUntilTheDaemonAgrees() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus(paused: false))
    let daemon = link(sandbox)
    daemon.reloadStatus()
    #expect(!daemon.paused)
    #expect(daemon.setPaused(true))
    #expect(daemon.paused)
    #expect(sandbox.control()?.paused == true)
    // A status written before the daemon read the request does not undo it.
    daemon.reloadStatus()
    #expect(daemon.paused)
    try sandbox.writeStatus(daemonStatus(paused: true))
    daemon.reloadStatus()
    #expect(daemon.paused)
    // Now the daemon's own word holds.
    try sandbox.writeStatus(daemonStatus(paused: false))
    daemon.reloadStatus()
    #expect(!daemon.paused)
}

@MainActor @Test func aPauseThatCannotBeWrittenIsNotShown() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus(paused: false))
    // A directory where the control file goes: the write fails.
    try FileManager.default.createDirectory(at: sandbox.locations.control, withIntermediateDirectories: true)
    let daemon = link(sandbox)
    var failures = 0
    daemon.controlFailed = { _ in failures += 1 }
    daemon.reloadStatus()
    #expect(daemon.daemonRunning)
    #expect(!daemon.setPaused(true))
    #expect(failures == 1)
    #expect(!daemon.paused)
}

@MainActor @Test func pausedNeedsARunningDaemon() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus(paused: true))
    let daemon = link(sandbox, alive: [])
    daemon.reloadStatus()
    #expect(!daemon.paused)
}

@MainActor @Test func theDaemonsConfigErrorCountsOnlyWhileItRuns() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus(configError: "dpi: out of range"))
    #expect({ let d = link(sandbox); d.reloadStatus(); return d.configError }() == "dpi: out of range")
    #expect({ let d = link(sandbox, alive: []); d.reloadStatus(); return d.configError }() == nil)
}

@MainActor @Test func theDPITokenIsSetRepeatedAndRenewed() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus())
    let daemon = link(sandbox)
    daemon.reloadStatus()
    daemon.requestConfiguredDPI()
    #expect(sandbox.control()?.useConfiguredDPI == 101)
    // Repeated in a later write, so a pause cannot erase it unread.
    daemon.setPaused(true)
    #expect(sandbox.control() == Control(paused: true, capture: nil, useConfiguredDPI: 101))
    daemon.requestConfiguredDPI()
    #expect(sandbox.control() == Control(paused: true, capture: nil, useConfiguredDPI: 102))
}

@MainActor @Test func applySettingsAgainIsANewTokenForEveryMouse() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus())
    let daemon = link(sandbox)
    daemon.reloadStatus()
    // A device left in the file by a DPI request must not narrow it.
    daemon.requestConfiguredDPI(device: "mb03400000000")
    daemon.requestReapply()
    #expect(sandbox.control()?.reapply == 102 && sandbox.control()?.device == nil)
    #expect(sandbox.control()?.useConfiguredDPI == 101)
    daemon.requestReapply()
    #expect(sandbox.control()?.reapply == 103)
}

@MainActor @Test func aNewerStatusStillMeansUpdateWhateverItAddsToADevice() throws {
    let sandbox = try Sandbox()
    let daemon = link(sandbox)
    // A later schema may give the applied state a value this build cannot decode.
    try sandbox.write(#"""
        {"schema": 4, "pid": 4242, "running": true, "devices": [{"id": "1", "applied": {"state": "somethingNew"}}]}
        """#, to: sandbox.locations.status)
    daemon.reloadStatus()
    #expect(daemon.statusTooNew && daemon.status == nil)
}

@MainActor @Test func everyControlWriteRingsTheDaemon() throws {
    let sandbox = try Sandbox()
    var rings = 0
    let daemon = DaemonLink(locations: sandbox.locations, isAlive: { _ in true }, ring: { rings += 1 })
    daemon.setPaused(true)
    daemon.requestConfiguredDPI()
    #expect(rings == 2)
}
