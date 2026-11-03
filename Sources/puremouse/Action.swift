import CoreGraphics
import Foundation
import PureMouseKit

extension Action {
    /// Whether performing it posts synthetic events (clicks, keys, scrolls, swipes), which needs
    /// Accessibility. Device actions, `run` (a shell command) and `none` do not.
    var postsEvents: Bool {
        switch self {
        case .none, .toggleScrollMode, .cycleDPI, .haptic, .run: false
        default: true
        }
    }
}

extension Config.Binding {
    /// Whether a press of a control bound this way can do something now. Without permission to
    /// post events, a posted action cannot, so its control stays native instead of going dead.
    /// A gesture needs one direction that can act: otherwise its raw motion would only freeze the
    /// pointer.
    func isPerformable(canPostEvents: Bool) -> Bool {
        if canPostEvents { return true }
        switch self {
        case .action(let action):
            return !action.postsEvents
        case .gesture(let gesture):
            return [gesture.click, gesture.up, gesture.down, gesture.left, gesture.right].contains {
                if case .none = $0 { false } else { !$0.postsEvents }
            }
        }
    }
}

/// Performs actions that only touch the system (no device state).
@MainActor
enum SystemActions {
    static func perform(_ action: Action) {
        if let key = AuxKey.key(for: action) {
            AuxKey.press(key)
            return
        }
        switch action {
        case .none, .toggleScrollMode, .cycleDPI, .haptic:
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
            (SymbolicHotKey.keystroke(SymbolicHotKey.spaceLeft) ?? Keystroke(key: 123, modifiers: .maskControl)).post()
        case .spaceRight:
            (SymbolicHotKey.keystroke(SymbolicHotKey.spaceRight) ?? Keystroke(key: 124, modifiers: .maskControl)).post()
        case .navigateBack:
            NavigationSwipe.post(back: true)
        case .navigateForward:
            NavigationSwipe.post(back: false)
        case .volumeUp, .volumeDown, .mute, .playPause, .nextTrack, .previousTrack, .brightnessUp, .brightnessDown:
            break  // posted by `AuxKey.key(for:)` above
        case .middleClick:
            NativeButton.postMiddleClick()
        case .nextTab:
            Keystroke(key: 48, modifiers: .maskControl).post()
        case .previousTab:
            Keystroke(key: 48, modifiers: [.maskControl, .maskShift]).post()
        case .zoomIn:
            Keystroke(key: 24, modifiers: .maskCommand).post()  // cmd+=
        case .zoomOut:
            Keystroke(key: 27, modifiers: .maskCommand).post()  // cmd+-
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
        // It lives in ApplicationServices, which PureMouse does not otherwise link.
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

    /// Starts a configured `run` command and returns at once. Its output is discarded (`shell`);
    /// a failure is logged once, when it ends.
    private static func run(_ command: String) {
        let process = shell(command)
        process.terminationHandler = { process in
            if let message = exitMessage(command, status: process.terminationStatus,
                                         reason: process.terminationReason) {
                Log.error(message)
            }
        }
        do {
            try process.run()
        } catch {
            Log.error("run \"\(shown(command))\": \(error)")
        }
    }

    /// `/bin/sh -c command` with stdout and stderr on /dev/null: a command's output must not reach
    /// the daemon's log, which only the daemon's own writes are counted and rotated by.
    nonisolated static func shell(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// The log line for a command that ended badly, or nil when it exited 0.
    nonisolated static func exitMessage(_ command: String, status: Int32,
                                        reason: Process.TerminationReason) -> String? {
        switch reason {
        case .exit where status == 0: nil
        case .exit: "run \"\(shown(command))\" exited \(status)"
        case .uncaughtSignal: "run \"\(shown(command))\" ended by signal \(status)"
        @unknown default: "run \"\(shown(command))\" ended (\(status))"
        }
    }

    /// A command as the log shows it: one line, at most 80 characters.
    nonisolated static func shown(_ command: String) -> String {
        let line = command.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count <= 80 ? line : line.prefix(79) + "…"
    }
}
