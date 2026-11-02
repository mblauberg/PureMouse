import Foundation

/// Scroll feel presets: each sets `smoothScroll.acceleration` and `smoothScroll.smoothingMs`.
public enum Feel: String, CaseIterable, Identifiable, Sendable {
    case precise, balanced, gliding, custom
    public var id: Self { self }

    public static let presets: [Feel] = [.precise, .balanced, .gliding]

    public var label: String {
        switch self {
        case .precise: "Precise"
        case .balanced: "Balanced"
        case .gliding: "Gliding"
        case .custom: "Custom"
        }
    }

    /// Feel's caption: what it changes, or, with values no preset matches (no segment selected),
    /// where to change them.
    public static func caption(for selection: Feel?) -> String {
        selection == nil ? "Custom. Adjust in Advanced." : "How long a scroll glides, and how far fast flicks go."
    }

    var values: (acceleration: Double, smoothingMs: Double)? {
        switch self {
        case .precise: (0.5, 60)
        case .balanced: (1.0, 125)
        case .gliding: (1.2, 350)
        case .custom: nil
        }
    }

    /// The preset matching these values (absent keys take the daemon's defaults), else `.custom`.
    static func matching(acceleration: Double?, smoothingMs: Double?) -> Feel {
        let a = acceleration ?? 1.0, s = smoothingMs ?? 125
        return presets.first {
            guard let v = $0.values else { return false }
            return abs(v.acceleration - a) < 0.001 && abs(v.smoothingMs - s) < 0.5
        } ?? .custom
    }
}

/// DPI preset lists: sorted, unique, at most `limit` (the daemon accepts 0–8).
public enum DPIPresets {
    public static let limit = 8

    public static func adding(_ dpi: Int, to presets: [Int]) -> [Int] {
        guard !presets.contains(dpi), presets.count < limit else { return presets }
        return (presets + [dpi]).sorted()
    }

    public static func removing(_ dpi: Int, from presets: [Int]) -> [Int] { presets.filter { $0 != dpi } }

    /// Whether "Add Preset" has anything to add: the speed is not saved yet and there is room.
    public static func canAdd(_ dpi: Int, to presets: [Int]) -> Bool {
        !presets.contains(dpi) && presets.count < limit
    }

    /// The preset the pointer speed is set to (its nearest step), the one the sheet checks and "−" removes.
    public static func selected(in presets: [Int], current: Int, steps: [Int]) -> Int? {
        presets.first { snap($0, to: steps) == current }
    }

    /// The Presets row's caption: "1,000, 1,650 and 3,200 DPI", or "None saved".
    public static func summary(_ presets: [Int]) -> String {
        guard let last = presets.last else { return "None saved" }
        guard presets.count > 1 else { return Format.dpi(last) }
        return presets.dropLast().map(Format.number).joined(separator: ", ") + " and " + Format.dpi(last)
    }

    /// Accessibility labels of the Presets sheet's controls.
    public static let addLabel = "Add Preset"
    public static func useLabel(_ dpi: Int) -> String { "Use \(Format.dpi(dpi))" }
    public static func removeLabel(_ dpi: Int) -> String { "Remove the \(Format.dpi(dpi)) preset" }

    /// The step of `steps` nearest to `dpi` (the sensor's own list; the daemon snaps the same way).
    public static func snap(_ dpi: Int, to steps: [Int]) -> Int {
        steps.min { abs($0 - dpi) < abs($1 - dpi) } ?? dpi
    }
}

/// The resolution the Pointer pane and the menu show. Three values stay apart: a change made here
/// and not yet reported back, the mouse's live value (which a Cycle Pointer Speed press changes
/// without touching the config), and the config's default.
public struct DPIReading: Equatable {
    public private(set) var requested: Int?
    private var requestedAt = Date.distantPast

    public init() {}

    /// How long a request may wait for the mouse to report it before a different report wins.
    static let settle: TimeInterval = 1.5

    public mutating func request(_ dpi: Int, at now: Date = .now) {
        requested = dpi
        requestedAt = now
    }

    public mutating func clear() { requested = nil }

    /// The mouse reported `live`. It confirms the request, or once the request has had time to
    /// land, replaces it (a button press changed the resolution).
    public mutating func reported(_ live: Int?, steps: [Int], at now: Date = .now) {
        guard let pending = requested, let live else { return }
        if live == DPIPresets.snap(pending, to: steps) || now.timeIntervalSince(requestedAt) > Self.settle {
            requested = nil
        }
    }

    /// A pending change, else the live value, else the configured one, else the sensor's default.
    public func current(live: Int?, configured: Int?) -> Int { requested ?? live ?? configured ?? 1000 }

    /// True when nothing has said what the speed is, so `current` is the sensor's usual default,
    /// not a reading: no pending change, no live value and no configured `dpi`.
    public func isEstimate(live: Int?, configured: Int?) -> Bool { requested == nil && live == nil && configured == nil }

    /// The value the Pointer pane shows: "1,650 DPI", or "About 1,000 DPI" for an estimate.
    public func readout(live: Int?, configured: Int?) -> String {
        (isEstimate(live: live, configured: configured) ? "About " : "")
            + Format.dpi(current(live: live, configured: configured))
    }

    /// The slider position of `dpi`: its nearest step, always a valid index (0 for an empty list).
    public static func index(of dpi: Int, in steps: [Int]) -> Int {
        steps.indices.min { abs(steps[$0] - dpi) < abs(steps[$1] - dpi) } ?? 0
    }

    /// The step at a slider position, clamped into the list.
    public static func step(at position: Double, in steps: [Int]) -> Int? {
        guard !steps.isEmpty else { return nil }
        return steps[min(max(Int(position.rounded()), 0), steps.count - 1)]
    }
}

public enum Format {
    public static func dpi(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic)) + " DPI"
    }

    public static func number(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }

    public static func multiplier(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value * 10 == (value * 10).rounded() ? 1 : 2))) + "×"
    }

    /// Scroll acceleration: a strength without a unit, since the distance it adds varies with
    /// the wheel's speed. 0 reads "Off".
    public static func strength(_ value: Double) -> String {
        value == 0 ? "Off" : value.formatted(.number.precision(.fractionLength(1)))
    }

    public static func millimetres(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " mm"
    }

    public static func milliseconds(_ value: Double) -> String { "\(Int(value.rounded())) ms" }

    /// Rounds a slider value to its step, so the config holds 0.75, not 0.7500000001.
    public static func snap(_ value: Double, step: Double) -> Double {
        let snapped = (value / step).rounded() * step
        return (snapped * 1000).rounded() / 1000
    }

    public static func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
