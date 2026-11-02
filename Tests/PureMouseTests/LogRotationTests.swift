import Foundation
import Testing
@testable import puremouse

@Suite struct LogRotationTests {
    /// Fixed-length lines, numbered, so a lost or split line shows.
    private static func lines(_ range: Range<Int>) -> [String] {
        range.map { String(format: "line %04d of the rotation test\n", $0) }
    }

    @Test func rotatesPastTheCapWithoutLosingALine() throws {
        let fixture = try LogFixture()
        let file = try #require(LogFile.attachStderr(url: fixture.log, fd: fixture.fd, rotateAt: 1000))
        let all = Self.lines(0..<50)  // 31 bytes each: one rotation, after line 32
        for line in all { file.write(Data(line.utf8)) }

        let rotated = URL(fileURLWithPath: fixture.log.path + ".1")
        let old = fixture.contents(rotated), new = fixture.contents()
        #expect(old.utf8.count > 1000)
        #expect(!new.isEmpty)
        #expect(old + new == all.joined())
    }

    @Test func logLinesFollowTheRotation() throws {
        let fixture = try LogFixture()
        let file = try #require(LogFile.attachStderr(url: fixture.log, fd: fixture.fd, rotateAt: 200))
        Log.$testOutput.withValue(.file(file)) {
            for n in 0..<5 { Log.info("message \(n) of five, long enough to pass the cap quickly") }
        }
        let rotated = URL(fileURLWithPath: fixture.log.path + ".1")
        let text = fixture.contents(rotated) + fixture.contents()
        #expect(fixture.contents(rotated).hasSuffix("\n"))
        for n in 0..<5 { #expect(text.contains("message \(n) of five")) }
    }

    @Test func replacesAnOlderRotatedFile() throws {
        let fixture = try LogFixture()
        let rotated = URL(fileURLWithPath: fixture.log.path + ".1")
        try FileManager.default.createDirectory(at: fixture.log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("older rotation\n".utf8).write(to: rotated)

        let file = try #require(LogFile.attachStderr(url: fixture.log, fd: fixture.fd, rotateAt: 100))
        for line in Self.lines(0..<4) { file.write(Data(line.utf8)) }

        #expect(fixture.contents(rotated) == Self.lines(0..<4).joined())
    }

    @Test func rotatesAtStartWhenAlreadyPastTheCap() throws {
        let fixture = try LogFixture()
        try FileManager.default.createDirectory(at: fixture.log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let earlier = Self.lines(0..<10).joined()
        try Data(earlier.utf8).write(to: fixture.log)

        _ = try #require(LogFile.attachStderr(url: fixture.log, fd: fixture.fd, rotateAt: 100))

        #expect(fixture.contents(URL(fileURLWithPath: fixture.log.path + ".1")) == earlier)
        #expect(fixture.contents().isEmpty)
    }

    @Test func leavesAFileOnAnotherInodeAlone() throws {
        let fixture = try LogFixture()
        let file = try #require(LogFile.attachStderr(url: fixture.log, fd: fixture.fd, rotateAt: 100))
        // Someone moves the log aside and starts another: fd now writes to the moved file.
        let moved = fixture.directory.appending(path: "moved.log")
        try FileManager.default.moveItem(at: fixture.log, to: moved)
        try Data("someone else's\n".utf8).write(to: fixture.log)

        let all = Self.lines(0..<10)
        for line in all { file.write(Data(line.utf8)) }

        #expect(!FileManager.default.fileExists(atPath: fixture.log.path + ".1"))
        #expect(fixture.contents() == "someone else's\n")
        #expect(fixture.contents(moved) == all.joined())
    }
}
