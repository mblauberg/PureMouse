import Foundation
import PureMouseKit

/// What the main wheel's three rows show and write in a scope (#146). A row always shows a
/// concrete value: a key that is not set reads as the mouse's default (not reversed, the wheel
/// mode the mouse reports, SmartShift on).
///
/// A choice is always written, with one exception: a mouse's scope removes its key when the choice
/// equals an explicit All Mice value, which the daemon applies to it anyway. The top level never
/// removes a key, and a mouse under an unset All Mice writes too. Removing a key would not undo
/// it: the daemon leaves the mouse as it last set it (wheel mode and SmartShift are written only
/// when set; with smooth scrolling off the wheel keeps the hardware's current direction), so Settings
/// would show a value the mouse does not have.
public enum WheelDefaults {
    public static let reversedPath = ["scrollWheel", "inverted"]
    public static let modePath = ["scrollWheel", "mode"]
    public static let smartShiftPath = ["scrollWheel", "smartShiftThreshold"]

    /// The threshold SmartShift on writes where nothing wider sets one, and the one that turns it off.
    public static let smartShiftOnThreshold = 12
    public static let smartShiftOffThreshold = 255

    public typealias Mode = Status.Device.WheelMode

    // MARK: Reading

    /// Reverse direction in `scope`: not reversed while unset.
    public static func isReversed(_ config: ConfigTree, in scope: ConfigScope) -> Bool {
        config.resolvedBool(reversedPath, in: scope) ?? false
    }

    /// Wheel mode in `scope`: the mouse's `live` mode while unset, Ratchet if it reports none.
    public static func mode(_ config: ConfigTree, in scope: ConfigScope, live: Mode?) -> Mode {
        (config.resolved(modePath, in: scope) as? String).flatMap(Mode.init(rawValue:)) ?? live ?? .ratchet
    }

    /// SmartShift in `scope`: on while unset.
    public static func smartShiftIsOn(_ config: ConfigTree, in scope: ConfigScope) -> Bool {
        isOn(config.resolvedInt(smartShiftPath, in: scope))
    }

    private static func isOn(_ threshold: Int?) -> Bool { threshold.map { $0 < smartShiftOffThreshold } ?? true }

    // MARK: Writing

    /// The user chose `reversed`. Written through `model.update(in: model.scopeTarget)`.
    public static func chooseReversed(_ reversed: Bool, in config: inout ConfigTree, scope: ConfigScope) {
        let inherited = parent(config, scope) { $0.resolvedBool(reversedPath, in: .global) }
        write(reversed == inherited ? nil : reversed, at: reversedPath, in: &config, scope: scope)
    }

    /// The user chose `mode`.
    public static func chooseMode(_ mode: Mode, in config: inout ConfigTree, scope: ConfigScope) {
        let inherited = parent(config, scope) { ($0.resolved(modePath, in: .global) as? String).flatMap(Mode.init(rawValue:)) }
        write(mode == inherited ? nil : mode.rawValue, at: modePath, in: &config, scope: scope)
    }

    /// The user chose SmartShift `on`: on writes 12 (also over an inherited off), off writes 255.
    public static func chooseSmartShift(_ on: Bool, in config: inout ConfigTree, scope: ConfigScope) {
        let inherited = parent(config, scope) { $0.resolvedInt(smartShiftPath, in: .global).map { isOn($0) } }
        write(on == inherited ? nil : (on ? smartShiftOnThreshold : smartShiftOffThreshold), at: smartShiftPath,
              in: &config, scope: scope)
    }

    /// What a mouse's scope inherits from an explicit All Mice value; nil for any other scope, and
    /// when All Mice sets nothing.
    private static func parent<V>(_ config: ConfigTree, _ scope: ConfigScope, _ read: (ConfigTree) -> V?) -> V? {
        scope.deviceKey == nil ? nil : read(config)
    }

    /// Writes `value`, or removes the key for nil.
    private static func write(_ value: Any?, at path: [String], in config: inout ConfigTree, scope: ConfigScope) {
        config.set(value, at: path, in: scope)
    }
}
