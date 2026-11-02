extension Log {
    struct Line: Sendable, Equatable {
        let level: String
        let message: String
    }

    /// Inherited by tasks a session starts, isolated from other tests' captures.
    @TaskLocal static var capture: (@Sendable (Line) -> Void)?
}

/// Session logging forwards to the existing stderr logger. The capture seam lives separately
/// because Log.swift is shared with the logging lane.
enum SessionLog {
    static func info(_ message: @autoclosure () -> String) {
        let message = message()
        Log.capture?(Log.Line(level: "info", message: message))
        Log.info(message)
    }

    static func error(_ message: @autoclosure () -> String) {
        let message = message()
        Log.capture?(Log.Line(level: "error", message: message))
        Log.error(message)
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard Log.verbose else { return }
        let message = message()
        Log.capture?(Log.Line(level: "debug", message: message))
        Log.debug(message)
    }
}
