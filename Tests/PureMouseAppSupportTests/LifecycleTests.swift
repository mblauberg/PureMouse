import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

@MainActor @Suite struct LifecycleTests {
    /// A stand-in for the daemon binary: a script that answers only `login-status`.
    private func stubDaemon(printing output: String, exiting status: Int = 0) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "puremouse")
        try Data("#!/bin/sh\n[ \"$1\" = login-status ] && cat <<'EOF'\n\(output)\nEOF\nexit \(status)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A stand-in daemon that answers every command with the arguments it was given.
    private func echoingDaemon() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "puremouse")
        try Data("#!/bin/sh\necho \"$@\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test(arguments: [
        (LoginAction.openAtLogin(true), "login on"), (.openAtLogin(false), "login off"),
        (.running(true), "start"), (.running(false), "stop"),
    ])
    func eachControlReachesTheCLIAsItsOwnCommand(action: LoginAction, expected: String) async throws {
        let daemon = try echoingDaemon()
        let output = await withCheckedContinuation { continuation in
            Lifecycle.run(action.command, daemon: daemon) { continuation.resume(returning: (try? $0.get()) ?? "failed") }
        }
        #expect(output == expected)
    }

    /// The alert body says what to do; the command's raw output stays out of it.
    @Test func aFailedCommandShowsAnInstructionNotItsOutput() async throws {
        let daemon = try stubDaemon(printing: "launchd said no: Bootstrap failed: 5", exiting: 1)
        let result = await withCheckedContinuation { continuation in
            Lifecycle.run(.loginStatus, daemon: daemon) { continuation.resume(returning: $0) }
        }
        let error = try #require({ if case .failure(let error) = result { error } else { nil } }())
        #expect(error.description == "Try again. If it keeps happening, restart your Mac.")
        #expect(!error.description.contains("launchd"))
        #expect(LifecycleError.failed("").description == error.description)
        #expect(LifecycleError.noDaemon.description == "Install PureMouse from the disk image, then open it again.")
    }

    private func read(from daemon: URL?) async -> LoginStatus? {
        await withCheckedContinuation { continuation in
            Lifecycle.readLoginStatus(daemon: daemon) { continuation.resume(returning: $0) }
        }
    }

    @Test func loginStatusIsReadThroughTheDaemonCLI() async throws {
        let daemon = try stubDaemon(printing: #"{"service":"launchd","daemon":"enabled","menu":"enabled","hidden":false}"#)
        #expect(await read(from: daemon)?.startsAtLogin == true)
    }

    /// Runs `menu off` against a daemon that exits with `status`, the way `call` makes the
    /// request, and returns what happened in order. The alert, or a success, ends the wait.
    private func perform(exiting status: Int, _ call: (AppModel, @escaping @MainActor (String) -> Void) -> Void) async throws -> [String] {
        let sandbox = try Sandbox()
        var locations = sandbox.locations
        locations.daemon = try stubDaemon(printing: "", exiting: status)
        var events: [String] = []
        var model: AppModel?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            model = AppModel(locations: locations, alert: { title, _ in events.append("alert: \(title)"); done.resume() })
            call(model!) { event in
                events.append(event)
                if event == "success" { done.resume() }
            }
        }
        return events
    }

    /// The shape of the call sites (`perform(.register) { refreshStartsAtLogin() }`, the menu's
    /// hide): an unlabelled trailing closure runs on success only.
    @Test func aTrailingClosureRunsOnlyOnSuccess() async throws {
        for status in [0, 1] {
            let events = try await perform(exiting: status) { model, record in
                model.perform(.menuOff) { record("success") }
            }
            #expect(events == (status == 0 ? ["success"] : ["alert: PureMouse couldn't do that."]))
        }
    }

    /// A failed command runs the caller's failure handler, so a switch can go back, then alerts.
    @Test func aFailedCommandRunsTheFailureHandlerThenAlerts() async throws {
        for status in [0, 1] {
            let events = try await perform(exiting: status) { model, record in
                model.perform(.menuOff, then: { record("success") }, otherwise: { record("failure") })
            }
            #expect(events == (status == 0 ? ["success"] : ["failure", "alert: PureMouse couldn't do that."]))
        }
    }

    @Test func loginStatusIsNilWhenTheAnswerCannotBeUsed() async throws {
        #expect(await read(from: try stubDaemon(printing: "not json")) == nil)
        #expect(await read(from: URL(fileURLWithPath: "/nonexistent/puremouse")) == nil)
        #expect(await read(from: nil) == nil)
        let json = #"{"service":"launchd","daemon":"enabled","menu":"enabled","hidden":false}"#
        #expect(await read(from: try stubDaemon(printing: json, exiting: 1)) == nil)
    }
}
