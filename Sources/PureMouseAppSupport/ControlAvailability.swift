import PureMouseKit

/// Whether a Settings control shows for the mice it describes, judged control by control from
/// the capabilities they report (docs/ui-design.md, "Hide or dim"). A control is hidden only when
/// every known mouse reports every capability it needs as false and the config holds nothing for
/// it; a value already set keeps it shown and editable, with a caption saying so, since it still
/// applies to other mice.
public enum ControlAvailability: Equatable, Sendable {
    case available
    case unsupportedButConfigured
    case hidden

    public typealias Capability = KeyPath<Status.Device.Capabilities, Bool?>

    /// The caption a shown control carries when the mouse lacks what it needs.
    public static let unsupportedCaption = "Not supported by this mouse."

    /// `needs`: any one suffices. `devices`: the mice the control describes; empty when none is
    /// known (no mouse, or PureMouse off or paused), which leaves every control available.
    public static func of(_ needs: [Capability], devices: [Status.Device], configured: Bool) -> ControlAvailability {
        let offered = devices.isEmpty || devices.contains { device in needs.contains { device.offers($0) } }
        if offered { return .available }
        return configured ? .unsupportedButConfigured : .hidden
    }

    /// The mice that decide: the primary one while it is online and PureMouse runs unpaused.
    /// Otherwise none, so every control shows and stays editable (offline editing).
    public static func devices(primary: Status.Device?, running: Bool, paused: Bool) -> [Status.Device] {
        guard running, !paused, let primary, primary.online else { return [] }
        return [primary]
    }

    public var isShown: Bool { self != .hidden }

    /// "Not supported by this mouse." for a control kept only by its value.
    public var caption: String? { self == .unsupportedButConfigured ? Self.unsupportedCaption : nil }
}

extension AppModel {
    /// The mice whose capabilities decide which controls show (`ControlAvailability.devices`).
    /// With several mice, which one a pane describes is still the primary one.
    public var capabilityDevices: [Status.Device] {
        ControlAvailability.devices(primary: primaryDevice, running: daemonRunning, paused: paused)
    }
}
