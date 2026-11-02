import Foundation

/// Timestamped lines on stderr. When the daemon runs as a login agent, `main` attaches stderr to
/// ~/Library/Logs/PureMouse.log first (`LogFile`), which rotates it at `rotateAt`.
enum Log {
    nonisolated(unsafe) static var verbose = false

    /// Where lines go when stderr is the log file: set once at the start of `run`, before any
    /// other thread logs. Nil from a terminal and for every other command.
    nonisolated(unsafe) static var file: LogFile?

    /// Overrides `file` for one task tree, so tests can log to their own file in parallel.
    @TaskLocal static var testFile: LogFile?

    /// The log moves to PureMouse.log.1 once a write takes it past this size, so the two files
    /// hold about 2 MiB at most.
    static let rotateAt = 1 << 20

    static func info(_ message: @autoclosure () -> String) {
        write("info", message())
    }

    static func debug(_ message: @autoclosure () -> String) {
        if verbose { write("debug", message()) }
    }

    static func error(_ message: @autoclosure () -> String) {
        write("error", message())
    }

    private static let timeFormat = Date.ISO8601FormatStyle(timeZone: .current)
        .year().month().day().time(includingFractionalSeconds: true)

    private static func write(_ level: String, _ message: String) {
        let time = Date.now.formatted(timeFormat)
        let line = Data("\(time) \(level) \(message)\n".utf8)
        if let file = testFile ?? file {
            file.write(line)
        } else {
            FileHandle.standardError.write(line)
        }
    }
}

/// The daemon's log file, attached to stderr so that anything written there lands in it.
///
/// The daemon owns the file rather than launchd (`StandardErrorPath`), so it can rotate it: once a
/// write takes it past `Log.rotateAt`, the file is renamed to `<name>.1` (replacing any older one)
/// and a fresh one is opened onto the same descriptor. A run from a terminal keeps printing there
/// and never touches the file. No timer: the size check runs on writes. Only the daemon's own lines
/// are counted, so nothing else may write to the descriptor: `run` commands get /dev/null.
final class LogFile: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/PureMouse.log")

    let url: URL
    /// The descriptor the log is attached to: 2 (stderr) in the daemon, another in tests.
    let fd: Int32
    let rotateAt: Int

    private let lock = NSLock()
    /// Bytes in the file: its size when attached, plus every line written since.
    private var size: Int

    private init(url: URL, fd: Int32, rotateAt: Int) {
        self.url = url
        self.fd = fd
        self.rotateAt = rotateAt
        var info = stat()
        size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
    }

    /// Points `fd` at the log file, appending, unless `fd` is a terminal (nil: nothing to do).
    /// Rotates once if the file is already past `rotateAt`. Returns nil if the file cannot be
    /// opened, leaving `fd` as it was.
    static func attachStderr(url: URL = defaultURL, fd: Int32 = STDERR_FILENO,
                             rotateAt: Int = Log.rotateAt) -> LogFile? {
        guard isatty(fd) == 0 else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard reopen(url, onto: fd) else { return nil }
        let file = LogFile(url: url, fd: fd, rotateAt: rotateAt)
        file.lock.withLock { file.rotateLocked() }
        return file
    }

    /// Writes all of `data` to the log, then rotates if that took it past `rotateAt`. Lines from
    /// several threads never interleave or straddle a rotation.
    func write(_ data: Data) {
        lock.withLock {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += count
                }
            }
            size += data.count
            rotateLocked()
        }
    }

    /// Renames the file to `<name>.1` and opens a fresh one onto `fd`, once it is past
    /// `rotateAt`, and only while `fd` still is that file (it is left alone if someone moved it).
    private func rotateLocked() {
        guard size > rotateAt, Self.refersTo(url, fd) else { return }
        let old = url.path + ".1"
        // Count afresh even if this fails, so a failure is retried a cap later, not on every line.
        size = 0
        guard rename(url.path, old) == 0 else { return }
        // Without a new file, put the old one back rather than leave fd writing to `<name>.1`.
        if !Self.reopen(url, onto: fd) { rename(old, url.path) }
    }

    /// Whether `fd` is the file at `url` (same device and inode).
    private static func refersTo(_ url: URL, _ fd: Int32) -> Bool {
        var open = stat(), named = stat()
        guard fstat(fd, &open) == 0, stat(url.path, &named) == 0 else { return false }
        return open.st_dev == named.st_dev && open.st_ino == named.st_ino
    }

    private static func reopen(_ url: URL, onto fd: Int32) -> Bool {
        let new = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard new >= 0 else { return false }
        return move(new, onto: fd)
    }

    /// Puts the open descriptor `new` at `fd` and closes `new`. With `fd` closed (`2>&-`), open
    /// already handed back `fd` itself: that one is kept, without the O_CLOEXEC that dup2 would
    /// have dropped.
    static func move(_ new: Int32, onto fd: Int32) -> Bool {
        if new == fd { return fcntl(fd, F_SETFD, 0) == 0 }
        defer { close(new) }
        return dup2(new, fd) >= 0
    }
}
