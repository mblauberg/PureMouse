import CoreGraphics
import Foundation

/// Something a button or gesture direction does. In config JSON an action is either a name
/// (`"missionControl"`) or an object: `{"keys": "cmd+shift+4"}` or `{"run": "open -a Safari"}`.
enum Action: Equatable, Decodable {
    case none
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight
    case navigateBack
    case navigateForward
    /// Flip the scroll wheel between ratchet and free-spin. Handled by the device session.
    case toggleScrollMode
    case keys(Keystroke)
    case run(String)

    private static let named: [String: Action] = [
        "none": .none, "missionControl": .missionControl, "appExpose": .appExpose,
        "showDesktop": .showDesktop, "launchpad": .launchpad, "spaceLeft": .spaceLeft,
        "spaceRight": .spaceRight, "navigateBack": .navigateBack, "navigateForward": .navigateForward,
        "toggleScrollMode": .toggleScrollMode,
    ]

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard let action = Self.named[name] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "unknown action '\(name)'; known: \(Self.named.keys.sorted().joined(separator: ", "))"))
            }
            self = action
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        if let spec = try c.decodeIfPresent(String.self, forKey: AnyKey("keys")) {
            guard let keystroke = Keystroke(spec) else {
                throw DecodingError.dataCorruptedError(forKey: AnyKey("keys"), in: c,
                                                       debugDescription: "cannot parse keystroke '\(spec)'")
            }
            self = .keys(keystroke)
        } else if let command = try c.decodeIfPresent(String.self, forKey: AnyKey("run")) {
            self = .run(command)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "expected an action name, {\"keys\": ...} or {\"run\": ...}"))
        }
    }
}

/// Performs actions that only touch the system (no device state).
@MainActor
enum SystemActions {
    static func perform(_ action: Action) {
        switch action {
        case .none, .toggleScrollMode:
            break
        case .missionControl:
            dock("com.apple.expose.awake", fallback: Keystroke(key: 126, modifiers: .maskControl))
        case .appExpose:
            dock("com.apple.expose.front.awake", fallback: Keystroke(key: 125, modifiers: .maskControl))
        case .showDesktop:
            dock("com.apple.showdesktop.awake", fallback: Keystroke(key: 103, modifiers: []))
        case .launchpad:
            dock("com.apple.launchpad.toggle", fallback: nil)
        case .spaceLeft:
            Keystroke(key: 123, modifiers: .maskControl).post()
        case .spaceRight:
            Keystroke(key: 124, modifiers: .maskControl).post()
        case .navigateBack:
            NavigationSwipe.post(back: true)
        case .navigateForward:
            NavigationSwipe.post(back: false)
        case .keys(let keystroke):
            keystroke.post()
        case .run(let command):
            run(command)
        }
    }

    // The Dock's private notification entry point triggers Mission Control and friends exactly
    // as the trackpad does, independent of the user's keyboard shortcuts.
    private typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> Int32
    private static let coreDockSend: CoreDockSendNotification? = {
        // It lives in ApplicationServices, which mxd does not otherwise link.
        let framework = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(framework, RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDockSendNotification") else {
            Log.error("CoreDockSendNotification unavailable; using keyboard shortcuts")
            return nil
        }
        return unsafeBitCast(symbol, to: CoreDockSendNotification.self)
    }()

    private static func dock(_ notification: String, fallback: Keystroke?) {
        if let coreDockSend {
            _ = coreDockSend(notification as CFString, 0)
        } else {
            fallback?.post()
        }
    }

    private static func run(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
        } catch {
            Log.error("run '\(command)': \(error)")
        }
    }
}
