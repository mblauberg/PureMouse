import Foundation
import Testing
@testable import puremouse

/// `run` actions: a command's output never reaches the daemon's log, and a failure is one line.
@Suite struct RunCommandTests {
    @Test func outputGoesToDevNull() throws {
        // The child checks its own stdout and stderr, and exits 1 if either is anything else.
        let process = SystemActions.shell(
            "echo out; echo err >&2; [ /dev/fd/1 -ef /dev/null ] && [ /dev/fd/2 -ef /dev/null ]")
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test func aFailureIsOneLine() {
        #expect(SystemActions.exitMessage("true", status: 0, reason: .exit) == nil)
        #expect(SystemActions.exitMessage("make -C ~/x", status: 2, reason: .exit)
            == #"run "make -C ~/x" exited 2"#)
        #expect(SystemActions.exitMessage("sleep 9", status: 9, reason: .uncaughtSignal)
            == #"run "sleep 9" ended by signal 9"#)
    }

    @Test func longCommandsAreShortened() {
        #expect(SystemActions.shown("echo a\necho b") == "echo a echo b")
        let long = String(repeating: "x", count: 200)
        #expect(SystemActions.shown(long) == String(repeating: "x", count: 79) + "…")
        #expect(SystemActions.shown(String(repeating: "y", count: 80)).count == 80)
    }
}
