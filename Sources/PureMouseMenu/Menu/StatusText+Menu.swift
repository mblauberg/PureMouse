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
            } else if let percent = device.battery?.percent {
                parts.append("battery \(percent) percent")
            }
            if let standby = Standby(paused: state.paused, away: state.away) { parts.append(standby.spoken) }
        } else {
            parts.append("no mouse connected")
        }
        if state.needsAttention { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
