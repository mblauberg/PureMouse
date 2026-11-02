import AppKit

/// Login and lifecycle changes, all made by the daemon's CLI (docs/companion.md, "Login and
/// lifecycle"): `register`, `unregister`, `stop`, `menu on|off`.
@MainActor
enum Lifecycle {
    enum Command {
        case register, unregister, stop, menuOn, menuOff
        var arguments: [String] {
            switch self {
            case .register: ["register"]
            case .unregister: ["unregister"]
            case .stop: ["stop"]
            case .menuOn: ["menu", "on"]
            case .menuOff: ["menu", "off"]
            }
        }
    }

    private static var running = 0

    /// No command is running (the menu app waits for this before it relaunches).
    static var idle: Bool { running == 0 }

    /// Runs the command off the main thread and reports its output, or why it failed.
    static func run(_ command: Command, then completion: @escaping @MainActor (Result<String, LifecycleError>) -> Void) {
        guard let daemon = Paths.daemon else {
            completion(.failure(.noDaemon))
            return
        }
        running += 1
        let completion: @MainActor (Result<String, LifecycleError>) -> Void = { result in
            completion(result) // may show an alert; still running until it is answered
            running -= 1
            AppController.shared?.relaunchIfIdle()
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = daemon
        process.arguments = command.arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = process.terminationStatus
            DispatchQueue.main.async {
                completion(status == 0 ? .success(output) : .failure(.failed(output)))
            }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(.failed(error.localizedDescription)))
        }
    }

    /// Runs the command and shows an alert if it fails.
    static func perform(_ command: Command, then success: @escaping @MainActor () -> Void = {}) {
        run(command) { result in
            switch result {
            case .success: success()
            case .failure(let error): Alerts.show("PureMouse could not do that", error.description)
            }
        }
    }
}

enum LifecycleError: Error, CustomStringConvertible {
    case noDaemon, failed(String)
    var description: String {
        switch self {
        case .noDaemon: "This copy of the menu bar app is not inside PureMouse.app."
        case .failed(let output): output.isEmpty ? "The command failed." : output
        }
    }
}

@MainActor
enum Alerts {
    static func show(_ message: String, _ info: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
        AppController.shared?.relaunchIfIdle() // it waited for this alert
    }

    /// A confirmation with a destructive default; returns true to go ahead.
    static func confirm(_ message: String, _ info: String, action: String, window: NSWindow? = NSApp.keyWindow) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        AppController.shared?.relaunchIfIdle()
        return confirmed
    }
}
