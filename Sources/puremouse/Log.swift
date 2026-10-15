import Foundation

/// Timestamped lines on stderr. The login agent sends stderr to ~/Library/Logs/PureMouse.log.
enum Log {
    nonisolated(unsafe) static var verbose = false

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
