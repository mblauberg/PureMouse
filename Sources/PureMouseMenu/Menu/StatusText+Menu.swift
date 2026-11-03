import PureMouseAppSupport
import PureMouseKit

extension StatusText {
    /// VoiceOver label for the status item. `primary`: the mouse the menu describes.
    static func accessibilityLabel(_ state: MenuState, primary: Status.Device?) -> String {
        var parts = ["PureMouse"]
        if !state.daemonRunning {
            parts.append("off")
        } else if let device = primary {
            parts.append(device.name)
            if !device.online {
                parts.append("asleep")
            } else if let battery = device.battery {
                if let percent = battery.percent {
                    parts.append("battery \(percent) percent")
                } else if battery.level == .low || battery.level == .critical {
                    // A level without a percentage still tells the person to charge it.
                    parts.append("battery \(battery.level.rawValue)")
                }
            }
        } else {
            parts.append("no mouse connected")
        }
        // Said with or without a mouse: a paused PureMouse lists none.
        if state.daemonRunning, let standby = Standby(paused: state.paused, away: state.away) {
            parts.append(standby.spoken)
        }
        // Every mouse answering, so two of one model are two: the count of the menu's headers.
        let mice = state.devices.filter(\.online).count
        if state.daemonRunning, mice >= 2 { parts.append("\(mice) mice connected") }
        if state.needsAttention { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
