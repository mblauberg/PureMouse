extension Log {
    struct Line: Sendable, Equatable {
        let level: String
        let message: String
    }

    /// Inherited by tasks a session starts, isolated from other tests' captures.
    @TaskLocal static var capture: (@Sendable (Line) -> Void)?
}

/// Capture session messages without replacing stderr or sharing mutable flags between tasks;
/// production output still goes through the existing logger.
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
