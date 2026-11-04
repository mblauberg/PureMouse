import Dispatch
import Foundation
import PureMouseKit
import Testing
@testable import puremouse

/// Collects errors thrown on worker threads so the test can fail on them.
private final class Errors: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func record(_ error: Error) { lock.lock(); all.append("\(error)"); lock.unlock() }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return all }
}

@MainActor @Suite struct ClearControlTests {
    nonisolated private static let bound: DispatchTimeInterval = .seconds(10)
    // The workers run on their own threads, not a global queue: with the whole suite running in
    // parallel, a global-queue block could wait longer than `bound` to start (#170).

    private func makeControl() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClearControlTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let control = directory.appending(path: "control.json")
        try Data(#"{"paused":true}"#.utf8).write(to: control)
        return (directory, control)
    }

    /// The menu holds `control.json.lock` mid-write as the daemon starts. The worker holds the lock
    /// until the clear has either finished (an unlocked delete) or provably not, within `grace`,
    /// then writes. A locked delete waits for that write and removes it; an unlocked one runs first
    /// and the write lands after it, leaving the file. Ordering is by signals; `grace` is a bounded
    /// wait that only ever expires when the delete is correctly blocked.
    @Test func theStartupClearWaitsForAWriteInProgress() throws {
        let (directory, control) = try makeControl()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = Errors()
        let locked = DispatchSemaphore(value: 0)
        let cleared = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let clearedWhileHeld = Box()
        Thread.detachNewThread {
            do {
                try FileLock.withLock(FileLock.url(for: control)) {
                    locked.signal()
                    clearedWhileHeld.value = cleared.wait(timeout: .now() + .milliseconds(150)) == .success
                    try Data(#"{"paused":true,"capture":{"token":7}}"#.utf8).write(to: control, options: .atomic)
                }
            } catch { errors.record(error) }
            finished.signal()
        }
        #expect(locked.wait(timeout: .now() + Self.bound) == .success)
        let clearer = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            StatusChannel.clearControl(control, timeout: 10)
            cleared.signal()
            clearer.signal()
        }
        #expect(finished.wait(timeout: .now() + Self.bound) == .success)
        #expect(clearer.wait(timeout: .now() + Self.bound) == .success)
        #expect(errors.messages.isEmpty, "\(errors.messages)")
        #expect(!clearedWhileHeld.value)
        #expect(!FileManager.default.fileExists(atPath: control.path))
    }

    /// A holder that outlasts the deadline: the clear returns, leaves the file and never deletes unlocked.
    @Test func aStuckHolderMakesTheClearGiveUpWithoutDeleting() throws {
        let (directory, control) = try makeControl()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = Errors()
        let locked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do {
                try FileLock.withLock(FileLock.url(for: control)) {
                    locked.signal()
                    _ = release.wait(timeout: .now() + Self.bound)
                }
            } catch { errors.record(error) }
            finished.signal()
        }
        #expect(locked.wait(timeout: .now() + Self.bound) == .success)
        StatusChannel.clearControl(control, timeout: 0.1)
        #expect(FileManager.default.fileExists(atPath: control.path))
        release.signal()
        #expect(finished.wait(timeout: .now() + Self.bound) == .success)
        #expect(errors.messages.isEmpty, "\(errors.messages)")
    }
}

private final class Box: @unchecked Sendable {
    var value = false
}
