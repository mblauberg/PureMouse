import Foundation
import PureMouseKit

/// The mouse pop-up on Settings' Mouse tab: which mice it lists, which one is chosen, and what the
/// panes read and write for it (docs/configuration.md, "Settings and per-mouse values").
extension AppModel {
    /// The mice to choose from (`MouseScope.known`).
    public var knownMice: [KnownMouse] { MouseScope.known(devices: devices, config: config) }

    /// A reported mouse cannot be told apart from the others (`MouseScope.hasUnidentified`).
    public var hasUnidentifiedMouse: Bool { MouseScope.hasUnidentified(devices: devices) }

    /// The pop-up shows: two or more mice are known, or the config has a `devices` entry.
    public var showsMouseMenu: Bool { MouseScope.offersChoice(known: knownMice, config: config) }

    /// The mouse the panes edit, or nil for All Mice. The remembered choice applies only while the
    /// pop-up shows and still lists that mouse; otherwise the panes edit the top level, as they do
    /// for one mouse.
    public var selectedMouse: KnownMouse? {
        guard let key = rememberedMouse, showsMouseMenu else { return nil }
        return knownMice.first { $0.key == key }
    }

    /// The scope the panes read and write.
    public var scope: ConfigScope { selectedMouse.flatMap { ConfigScope.device($0.key) } ?? .global }

    /// `scope` with the name a first write gives the mouse's entry.
    public var scopeTarget: ScopeTarget { ScopeTarget(scope: scope, name: selectedMouse?.name) }

    /// Chooses a mouse by device key, or All Mice with nil. Remembered for next time. A key that
    /// is not a device key is All Mice.
    public func selectMouse(_ key: String?) {
        let folded = key?.lowercased()
        let key = folded.flatMap { Config.isDeviceKey($0) ? $0 : nil }
        guard key != rememberedMouse else { return }
        rememberedMouse = key
        if let key { defaults.set(key, forKey: Self.mouseKey) } else { defaults.removeObject(forKey: Self.mouseKey) }
    }

    /// Opens the scope a `ShowRequest` asks for: the mouse it names, or All Mice for a presets sheet
    /// that names none (the menu showed the top level's presets). Anything else leaves the choice.
    /// A mouse the pop-up does not list falls back to All Mice (`selectedMouse`).
    public func select(for request: ShowRequest) {
        if request.device != nil || request.sheet == .presets { selectMouse(request.device) }
    }

    /// A control was pressed on a mouse (Find by Pressing): its settings are the ones to edit,
    /// when the pop-up offers the choice.
    func selectCapturedMouse(_ key: String?) {
        guard let key = key?.lowercased(), showsMouseMenu, knownMice.contains(where: { $0.key == key }) else { return }
        selectMouse(key)
    }

    // MARK: Reading a scope

    /// The reported mice `scope` describes.
    public func devices(in scope: ConfigScope) -> [Status.Device] { MouseScope.described(devices: devices, scope: scope) }

    /// The mouse whose live values a pane shows in `scope`: the first one connected and answering.
    /// For All Mice, the same as the status menu's.
    public func liveDevice(in scope: ConfigScope) -> Status.Device? {
        scope.deviceKey == nil ? liveDevice : (daemonRunning ? devices(in: scope).first(where: \.online) : nil)
    }

    /// The mouse whose DPI steps a pane offers in `scope`: its live one, else the last seen.
    public func primaryDevice(in scope: ConfigScope) -> Status.Device? {
        scope.deviceKey == nil ? primaryDevice : (liveDevice(in: scope) ?? devices(in: scope).first)
    }

    /// The controls the Buttons list offers in `scope`, from what the mice report: nil while none
    /// has reported any (the default list shows).
    public func reportedControlIDs(in scope: ConfigScope) -> [UInt16] { devices(in: scope).flatMap(\.controls).map(\.cid) }

    /// The config keys under `buttons` that make a control listed: the top level's and the mouse's
    /// own in its scope. A binding the default set gives is no reason to list a control a mouse
    /// lacks, so the top level counts only what differs from it.
    public func boundButtonKeys(in scope: ConfigScope) -> [String] {
        let global = (config[["buttons"]] as? [String: Any] ?? [:]).keys.filter { config.holdsBeyondDefaults(["buttons", $0]) }
        guard scope != .global else { return Array(global) }
        let own = (config[config.prefix(of: scope) + ["buttons"]] as? [String: Any]).map { Array($0.keys) } ?? []
        return Array(global) + own
    }
}
