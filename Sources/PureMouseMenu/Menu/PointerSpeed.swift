import PureMouseAppSupport

extension AppModel {
    /// Pointer Speed from the status menu: under `devices.<device>` for that mouse, which is then
    /// the only one asked to apply it, else the top level (`setDPI`, every mouse). A key Kit would
    /// not read as a device key writes the top level, never an entry the decoder skips.
    func setPointerSpeed(_ dpi: Int, device: String?) {
        guard let key = device, let scope = ConfigScope.device(key) else { return setDPI(dpi) }
        let name = devices.first { $0.deviceKey == key }?.name
        setDPI(dpi, in: ScopeTarget(scope: scope, name: name))
    }
}
