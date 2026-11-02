import Foundation
import Testing
@testable import puremouse

/// A temporary directory with a log path in it, and a descriptor standing in for stderr.
final class LogFixture {
    let directory: URL
    let log: URL
    /// The stand-in for fd 2: a scratch file, so the tests never touch the runner's stderr.
    let fd: Int32

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PureMouseLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appending(path: "Logs/PureMouse.log")
        fd = open(directory.appending(path: "stderr").path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
    }

    deinit {
        close(fd)
        try? FileManager.default.removeItem(at: directory)
    }

    func contents(_ url: URL? = nil) -> String {
        (try? String(contentsOf: url ?? log, encoding: .utf8)) ?? ""
    }
}

@Suite struct LogFileTests {
    @Test func linesAppendAfterExistingContent() throws {
        let fixture = try LogFixture()
        try FileManager.default.createDirectory(at: fixture.log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("earlier run\n".utf8).write(to: fixture.log)

        let file = try #require(LogFile.attachStderr(url: fixture.log, fd: fixture.fd))
        Log.$testFile.withValue(file) { Log.info("PureMouse dev on macOS test") }

        let lines = fixture.contents().split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first == "earlier run")
        #expect(lines.last?.hasSuffix(" info PureMouse dev on macOS test") == true)
    }

    @Test func createsTheLogDirectory() throws {
        let fixture = try LogFixture()
        let file = try #require(LogFile.attachStderr(url: fixture.log, fd: fixture.fd))
        Log.$testFile.withValue(file) { Log.error("first line") }
        #expect(fixture.contents().hasSuffix(" error first line\n"))
    }

    /// Under `2>&-` the daemon starts with fd 2 closed, so opening the log takes 2 itself.
    @Test func aClosedDescriptorIsReopenedAndKept() throws {
        let fixture = try LogFixture()
        // The lowest free number, as 2 is when closed: open() hands it straight back. (Another
        // test may take it first; the checks below hold either way.)
        let free = open("/dev/null", O_RDONLY)
        try #require(free >= 0)
        close(free)

        let file = try #require(LogFile.attachStderr(url: fixture.log, fd: free))
        defer { close(free) }
        #expect(fcntl(free, F_GETFD) == 0)  // open, and inherited across exec like stderr
        Log.$testFile.withValue(file) { Log.info("still open") }
        #expect(fixture.contents().hasSuffix(" info still open\n"))
    }

    @Test func aTerminalIsLeftAlone() throws {
        let fixture = try LogFixture()
        let terminal = try PseudoTerminal()
        #expect(LogFile.attachStderr(url: fixture.log, fd: terminal.fd) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.log.path))
    }
}

/// The controlling side of a pseudo-terminal: `isatty` is true for it, as for a terminal's stderr.
final class PseudoTerminal {
    let primary: Int32
    let fd: Int32

    init() throws {
        primary = posix_openpt(O_RDWR | O_NOCTTY)
        if primary >= 0, grantpt(primary) == 0, unlockpt(primary) == 0, let name = ptsname(primary) {
            fd = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC)
        } else {
            fd = -1
        }
        guard fd >= 0, isatty(fd) == 1 else {
            if primary >= 0 { close(primary) }
            throw POSIXError(.ENOTTY)
        }
    }

    deinit {
        close(fd)
        close(primary)
    }
}
