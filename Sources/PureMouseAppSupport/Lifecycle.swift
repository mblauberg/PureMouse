import Foundation
import PureMouseKit

/// Login and lifecycle changes, all made by the daemon's CLI (docs/companion.md, "Login and
/// lifecycle"): `register`, `unregister`, `stop`, `menu on|off`, and the read of `login-status`.
@MainActor
public enum Lifecycle {
    public enum Command: Sendable {
        case register, unregister, stop, menuOn, menuOff, loginStatus
        var arguments: [String] {
            switch self {
            case .loginStatus: ["login-status"]
            case .register: ["register"]
            case .unregister: ["unregister"]
            case .stop: ["stop"]
            case .menuOn: ["menu", "on"]
            case .menuOff: ["menu", "off"]
            }
        }
    }

    /// Asks the daemon's CLI whether PureMouse starts at login; nil when it cannot be asked or its
    /// answer is not understood.
    public static func readLoginStatus(daemon: URL? = Locations.live.daemon,
                                       then completion: @escaping @MainActor (LoginStatus?) -> Void) {
        run(.loginStatus, daemon: daemon) { completion((try? $0.get()).flatMap(LoginStatus.parse)) }
    }

    /// Runs the command off the main thread and reports its output, or why it failed.
    public static func run(_ command: Command, daemon: URL? = Locations.live.daemon,
                           then completion: @escaping @MainActor (Result<String, LifecycleError>) -> Void) {
        guard let daemon else {
            completion(.failure(.noDaemon))
            return
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
}

public enum LifecycleError: Error, CustomStringConvertible {
    case noDaemon, failed(String)
    public var description: String {
        switch self {
        case .noDaemon: "This copy of the menu bar app is not inside PureMouse.app."
        case .failed(let output): output.isEmpty ? "The command failed." : output
        }
    }
}
