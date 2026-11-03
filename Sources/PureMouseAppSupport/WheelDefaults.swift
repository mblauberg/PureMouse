import Foundation
import PureMouseKit

/// What the main wheel's three rows show and write in a scope (#146). A row always shows a
/// concrete value: a key that is not set reads as the mouse's default (not reversed, the wheel
/// mode the mouse reports, SmartShift on). A key is written only when the choice differs from
/// what the scope would have without it, which is the value an explicit wider scope sets, else
/// that default; otherwise the key is removed, so the mouse keeps following.
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
        write(reversed, default: false, inherited: inherited, at: reversedPath, stored: reversed, in: &config, scope: scope)
    }

    /// The user chose `mode`; `live` is the mouse's own mode as it reports it.
    public static func chooseMode(_ mode: Mode, live: Mode?, in config: inout ConfigTree, scope: ConfigScope) {
        let inherited = parent(config, scope) { ($0.resolved(modePath, in: .global) as? String).flatMap(Mode.init(rawValue:)) }
        write(mode, default: live ?? .ratchet, inherited: inherited, at: modePath, stored: mode.rawValue, in: &config, scope: scope)
    }

    /// The user chose SmartShift `on`: on writes 12 over an inherited off, off writes 255.
    public static func chooseSmartShift(_ on: Bool, in config: inout ConfigTree, scope: ConfigScope) {
        let inherited = parent(config, scope) { $0.resolvedInt(smartShiftPath, in: .global).map { isOn($0) } }
        write(on, default: true, inherited: inherited, at: smartShiftPath,
              stored: on ? smartShiftOnThreshold : smartShiftOffThreshold, in: &config, scope: scope)
    }

    /// What a mouse's scope inherits from an explicit All Mice value; nil for any other scope, and
    /// when All Mice sets nothing.
    private static func parent<V>(_ config: ConfigTree, _ scope: ConfigScope, _ read: (ConfigTree) -> V?) -> V? {
        scope.deviceKey == nil ? nil : read(config)
    }

    private static func write<V: Equatable>(_ choice: V, default fallback: V, inherited: V?, at path: [String],
                                            stored: Any, in config: inout ConfigTree, scope: ConfigScope) {
        let follows = choice == (inherited ?? fallback)
        config.set(follows ? nil : stored, at: path, in: scope)
    }
}
