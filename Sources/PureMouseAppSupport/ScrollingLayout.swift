import PureMouseKit

/// The thumb wheel's rows in an Advanced… sheet (Scrolling's, or an app's), each shown only while
/// it applies to what the wheel does.
public enum ThumbWheelAdvancedRow: Hashable, CaseIterable, Sendable {
    /// `inverted`: scrolling only, and global only.
    case reverseScrolling
    /// `reversed`: swaps the actions.
    case swapDirections
    /// `step`.
    case turnDistance
    /// `smoothScroll.horizontalSpeed`: scrolling only, and global only.
    case speed

    /// The rows that apply. `scrolls`: the wheel scrolls at this path. `someAppScrolls`: it
    /// scrolls in some app, where `inverted` still matters. `inApp`: the rows are an app's, which
    /// has no `inverted` or speed of its own. `inherits`: the app leaves the action to the global
    /// one, so the step is the global one's too.
    public static func rows(scrolls: Bool, someAppScrolls: Bool, inApp: Bool, inherits: Bool) -> [ThumbWheelAdvancedRow] {
        allCases.filter {
            switch $0 {
            case .reverseScrolling: !inApp && (scrolls || someAppScrolls)
            case .swapDirections: !scrolls
            case .turnDistance: !scrolls && !inherits
            case .speed: !inApp && scrolls
            }
        }
    }
}

/// Which rows Mouse › Scrolling and its Advanced… sheet show, from what the mouse reports
/// (`ControlAvailability`) and what the settings make apply (a row for a mode not in use is hidden).
public struct ScrollingLayout {
    public enum Row: Hashable, CaseIterable, Sendable {
        // Shown by default.
        case smoothScrolling, feel, speed
        case reverseDirection, wheelMode, smartShift
        case thumbWheelAction
        // In the Advanced… sheet.
        case acceleration, glide, shiftScrollsSideways
        case switchesAt
        case thumbWheel(ThumbWheelAdvancedRow)

        public static var allCases: [Row] {
            [.smoothScrolling, .feel, .speed, .reverseDirection, .wheelMode, .smartShift, .thumbWheelAction,
             .acceleration, .glide, .shiftScrollsSideways, .switchesAt]
                + ThumbWheelAdvancedRow.allCases.map(Row.thumbWheel)
        }
    }

    let config: ConfigTree
    let devices: [Status.Device]
    let scope: ConfigScope

    /// `devices`: the mice the pane describes (`AppModel.capabilityDevices(in:)`); `scope`: All
    /// Mice or the one the pane edits, whose settings the rows that depend on a value read.
    public init(config: ConfigTree, devices: [Status.Device], scope: ConfigScope = .global) {
        self.config = config
        self.devices = devices
        self.scope = scope
    }

    /// Whether the mouse can use the row, from the capabilities it needs and the key that keeps
    /// it shown (#112's table).
    public func availability(_ row: Row) -> ControlAvailability {
        let (needs, key): ([ControlAvailability.Capability], [String]) = switch row {
        // The switch and the glide also shape the thumb wheel's scrolling.
        case .smoothScrolling, .feel, .acceleration, .glide, .shiftScrollsSideways:
            ([\.smoothScroll, \.thumbWheel], ["smoothScroll"])
        case .speed: ([\.smoothScroll], ["smoothScroll", "speed"])
        // The main wheel PureMouse can take over, which it then reverses itself if need be.
        case .reverseDirection: ([\.smoothScroll], ["scrollWheel", "inverted"])
        case .wheelMode: ([\.smartShift], ["scrollWheel", "mode"])
        case .smartShift, .switchesAt: ([\.smartShift], ["scrollWheel", "smartShiftThreshold"])
        case .thumbWheelAction, .thumbWheel: ([\.thumbWheel], ["thumbWheel"])
        }
        return ControlAvailability.of(needs, devices: devices, configured: config.holds(key, in: scope))
    }

    /// Whether the row shows: the mouse can use it and it applies to the current settings.
    public func shows(_ row: Row) -> Bool {
        guard availability(row).isShown else { return false }
        switch row {
        case .switchesAt: return smartShiftOn
        case .thumbWheel(let thumbRow): return thumbWheelRows.contains(thumbRow)
        default: return true
        }
    }

    /// SmartShift is on unless its threshold is 255 (or more).
    public var smartShiftOn: Bool { config.resolvedInt(["scrollWheel", "smartShiftThreshold"], in: scope).map { $0 < 255 } ?? true }

    /// The thumb wheel rows the settings in `scope` make apply. A mouse that leaves the action to
    /// All Mice has the step of that action too.
    var thumbWheelRows: [ThumbWheelAdvancedRow] {
        let inherits = scope.deviceKey != nil && config.thumbWheelChoice(at: config.prefix(of: scope) + ["thumbWheel"]) == .inherit
        return ThumbWheelAdvancedRow.rows(scrolls: config.thumbWheel(in: scope).scrolls,
                                          someAppScrolls: config.someAppScrollsThumbWheel, inApp: false, inherits: inherits)
    }

    /// The pane's groups: Smooth scrolling, Main Wheel and Thumb Wheel, each with the rows it
    /// shows (an empty group is not drawn).
    public var smoothScrollingRows: [Row] { [.smoothScrolling, .feel, .speed].filter(shows) }
    public var mainWheelRows: [Row] { [.reverseDirection, .wheelMode, .smartShift].filter(shows) }
    public var showsThumbWheel: Bool { shows(.thumbWheelAction) }

    /// No default row shows: the segment reads "Not supported by this mouse." instead.
    public var isEmpty: Bool { smoothScrollingRows.isEmpty && mainWheelRows.isEmpty && !showsThumbWheel }

    /// The Advanced… sheet's groups, likewise.
    public var advancedSmoothScrollingRows: [Row] { [.acceleration, .glide, .shiftScrollsSideways].filter(shows) }
    public var advancedMainWheelRows: [Row] { [.switchesAt].filter(shows) }
    public var advancedThumbWheelRows: [Row] { ThumbWheelAdvancedRow.allCases.map(Row.thumbWheel).filter(shows) }

    /// Advanced… is drawn only when its sheet would have a row.
    public var hasAdvanced: Bool {
        !(advancedSmoothScrollingRows.isEmpty && advancedMainWheelRows.isEmpty && advancedThumbWheelRows.isEmpty)
    }
}
