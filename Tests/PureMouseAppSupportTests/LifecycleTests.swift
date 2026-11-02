import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

@MainActor @Suite struct LifecycleTests {
    /// A stand-in for the daemon binary: a script that answers only `login-status`.
    private func stubDaemon(printing output: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "puremouse")
        try Data("#!/bin/sh\n[ \"$1\" = login-status ] && cat <<'EOF'\n\(output)\nEOF\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
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

    @Test func loginStatusIsNilWhenTheAnswerCannotBeUsed() async throws {
        #expect(await read(from: try stubDaemon(printing: "not json")) == nil)
        #expect(await read(from: URL(fileURLWithPath: "/nonexistent/puremouse")) == nil)
        #expect(await read(from: nil) == nil)
    }
}
