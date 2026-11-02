import PureMouseKit

extension Status.Device {
    /// The mouse the menu and the Pointer pane describe: the first one online, else the last seen.
    static func primary(of devices: [Status.Device]) -> Status.Device? {
        live(of: devices) ?? devices.first
    }

    /// The first mouse connected now and answering (live values come from it).
    static func live(of devices: [Status.Device]) -> Status.Device? { devices.first(where: \.online) }
}
