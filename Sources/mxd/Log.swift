import Foundation

/// Timestamped lines on stderr. The login agent sends stderr to ~/Library/Logs/mxd.log.
enum Log {
    nonisolated(unsafe) static var verbose = false

    /// Appends stderr to ~/Library/Logs/mxd.log.
    static func redirectToFile() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let fd = open(logs.appending(path: "mxd.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

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
        FileHandle.standardError.write(Data("\(time) \(level) \(message)\n".utf8))
    }
}
