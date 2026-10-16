import CoreGraphics
import Foundation
import PureMouseKit

/// Performs actions that only touch the system (no device state).
@MainActor
enum SystemActions {
    static func perform(_ action: Action) {
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
        case .volumeUp:
            AuxKey.press(AuxKey.soundUp)
        case .volumeDown:
            AuxKey.press(AuxKey.soundDown)
        case .mute:
            AuxKey.press(AuxKey.mute)
        case .brightnessUp:
            AuxKey.press(AuxKey.brightnessUp)
        case .brightnessDown:
            AuxKey.press(AuxKey.brightnessDown)
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
