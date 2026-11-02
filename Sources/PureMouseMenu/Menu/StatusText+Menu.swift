import PureMouseAppSupport

extension StatusText {
    /// VoiceOver label for the status item.
    @MainActor static func accessibilityLabel(model: AppModel) -> String {
        var parts = ["PureMouse"]
        if !model.daemonRunning {
            parts.append("off")
        } else if let device = model.primaryDevice {
            parts.append(device.name)
            if !device.online {
                parts.append("asleep")
            } else if let percent = device.battery?.percent {
                parts.append("battery \(percent) percent")
            }
            if model.paused {
                parts.append("paused")
            } else if model.status?.away == true {
                parts.append("on another Mac")
            }
        } else {
            parts.append("no mouse connected")
        }
        if model.needsAttention { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
