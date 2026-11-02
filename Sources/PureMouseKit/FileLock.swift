import Foundation

/// An advisory `flock` that makes a read-merge-replace of a shared file one step for every process
/// that takes it: the config's writers, `control.json`'s writers and the daemon's startup delete of
/// it. It locks a separate file beside the data, never the data itself: atomic writes give the data
/// a new inode each time, so a lock on it would guard nothing. `flock` belongs to the open file
/// description, so two opens in one process exclude each other too.
public enum FileLock {
    /// The lock file for `file`: `<name>.lock` in the same directory.
    public static func url(for file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".lock")
    }

    /// The lock could not be opened or taken; `body` did not run.
    public struct Failed: LocalizedError {
        public let path: String
        public let reason: String
        public var errorDescription: String? {
            "PureMouse could not lock \((path as NSString).abbreviatingWithTildeInPath): \(reason)"
        }

        init(_ lock: URL, errno code: Int32) { self.init(path: lock.path, reason: String(cString: strerror(code))) }
        init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// Runs `body` holding an exclusive lock on `lock` (created if needed), waiting while another
    /// writer holds it. Writers hold it for one read and one atomic write, so the wait is short
    /// and needs no timer. Closing the descriptor releases it, also when `body` throws.
    ///
    /// With a `timeout` the wait is bounded: a holder that outlasts it makes this throw `Failed`
    /// without running `body`, for callers (lifecycle commands) that can hold the lock for seconds.
    public static func withLock<T>(_ lock: URL, timeout: TimeInterval? = nil, _ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw Failed(path: lock.path, reason: error.localizedDescription)
        }
        let fd = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failed(lock, errno: errno) }
        defer { close(fd) }
        if let timeout {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else { throw Failed(lock, errno: errno) }
                guard Date() < deadline else {
                    throw Failed(path: lock.path, reason: "another PureMouse command was still running after \(Int(timeout.rounded(.up))) s")
                }
                usleep(50_000)
            }
        } else {
            while flock(fd, LOCK_EX) != 0 {
                guard errno == EINTR else { throw Failed(lock, errno: errno) }
            }
        }
        return try body()
    }
}
