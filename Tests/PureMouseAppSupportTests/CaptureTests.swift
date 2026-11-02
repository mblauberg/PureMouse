import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

@MainActor
private func running(_ sandbox: Sandbox, status: Status = daemonStatus()) throws -> DaemonLink {
    try sandbox.writeStatus(status)
    let daemon = DaemonLink(locations: sandbox.locations, isAlive: { _ in true }, ring: {})
    daemon.reloadStatus()
    return daemon
}

@MainActor @Test func captureWithNoAnswerEndsAfterElevenSeconds() throws {
    let sandbox = try Sandbox()
    let daemon = try running(sandbox)
    let manual = ManualClock()
    let capture = CaptureController(link: daemon, clock: manual.clock, newToken: { 77 })
    capture.start()
    #expect(capture.listening)
    #expect(sandbox.control()?.capture == Control.Capture(token: 77))
    #expect(manual.pending.map(\.seconds) == [11])
    manual.advance(10)
    #expect(capture.listening)
    manual.advance(11)
    #expect(!capture.listening)
    #expect(sandbox.control()?.capture == nil)
}

@MainActor @Test func aPressEndsTheCaptureAndNamesTheButton() throws {
    let sandbox = try Sandbox()
    let daemon = try running(sandbox)
    let manual = ManualClock()
    let capture = CaptureController(link: daemon, clock: manual.clock, newToken: { 77 })
    capture.start()
    // Another request's answer is ignored.
    capture.handle(Status.Capture(token: 5, state: .pressed, cid: 0x53, deviceID: "1-1"))
    #expect(capture.listening)
    capture.handle(Status.Capture(token: 77, state: .listening, cid: nil, deviceID: nil))
    #expect(capture.listening)
    capture.handle(Status.Capture(token: 77, state: .pressed, cid: 0x53, deviceID: "1-1"))
    #expect(!capture.listening)
    #expect(capture.capturedButton == "back")
    #expect(manual.pending.isEmpty)
    // A later control write no longer carries the request.
    daemon.setPaused(true)
    #expect(sandbox.control()?.capture == nil)
}

@MainActor @Test func captureNeedsARunningUnpausedDaemon() throws {
    let sandbox = try Sandbox()
    let off = DaemonLink(locations: sandbox.locations, isAlive: { _ in false }, ring: {})
    let capture = CaptureController(link: off, clock: ManualClock().clock)
    capture.start()
    #expect(!capture.listening && sandbox.control() == nil)
    let paused = try running(sandbox, status: daemonStatus(paused: true))
    let pausedCapture = CaptureController(link: paused, clock: ManualClock().clock)
    pausedCapture.start()
    #expect(!pausedCapture.listening)
}

@MainActor @Test func aCaptureEndsWhenTheDaemonDoes() throws {
    let sandbox = try Sandbox()
    var alive = true
    try sandbox.writeStatus(daemonStatus())
    let daemon = DaemonLink(locations: sandbox.locations, isAlive: { _ in alive }, ring: {})
    daemon.reloadStatus()
    let manual = ManualClock()
    let capture = CaptureController(link: daemon, clock: manual.clock)
    daemon.livenessChecked = { capture.checkDaemon() }
    capture.start()
    alive = false
    daemon.refreshLiveness()
    #expect(!capture.listening)
    #expect(manual.pending.isEmpty)
}

@MainActor @Test func cancellingTellsTheDaemon() throws {
    let sandbox = try Sandbox()
    let daemon = try running(sandbox)
    let capture = CaptureController(link: daemon, clock: ManualClock().clock, newToken: { 9 })
    capture.start()
    capture.cancel()
    #expect(!capture.listening)
    #expect(sandbox.control()?.capture == nil)
}

@MainActor @Test func startingAgainReplacesTheEarlierTimeout() throws {
    let sandbox = try Sandbox()
    let daemon = try running(sandbox)
    let manual = ManualClock()
    var tokens = [77, 78]
    let capture = CaptureController(link: daemon, clock: manual.clock, newToken: { tokens.removeFirst() })
    capture.start()
    capture.start()
    #expect(manual.pending.count == 1)
    #expect(sandbox.control()?.capture == Control.Capture(token: 78))
}
