import PureMouseKit

/// Which rows Mouse › Pointer shows, from what the mouse reports (`ControlAvailability`): a mouse
/// whose DPI cannot be adjusted hides them unless the config already sets `dpi` or `dpiPresets`,
/// which keeps them shown with the "Not supported by this mouse." caption.
public struct PointerLayout {
    let config: ConfigTree
    let devices: [Status.Device]

    /// `devices`: the mice the pane describes (`AppModel.capabilityDevices`).
    public init(config: ConfigTree, devices: [Status.Device]) {
        self.config = config
        self.devices = devices
    }

    /// Pointer Speed, Exact value and Presets all need adjustable DPI.
    public var availability: ControlAvailability {
        ControlAvailability.of([\.dpi], devices: devices,
                               configured: config.contains(["dpi"]) || config.contains(["dpiPresets"]))
    }

    public var showsRows: Bool { availability.isShown }
}
