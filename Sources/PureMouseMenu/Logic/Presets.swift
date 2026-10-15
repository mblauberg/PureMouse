import Foundation

/// Scroll feel presets: each sets `smoothScroll.acceleration` and `smoothScroll.smoothingMs`.
enum Feel: String, CaseIterable, Identifiable {
    case precise, balanced, gliding, custom
    var id: Self { self }

    static let presets: [Feel] = [.precise, .balanced, .gliding]

    var label: String {
        switch self {
        case .precise: "Precise"
        case .balanced: "Balanced"
        case .gliding: "Gliding"
        case .custom: "Custom"
        }
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
enum DPIPresets {
    static let limit = 8

    static func adding(_ dpi: Int, to presets: [Int]) -> [Int] {
        guard !presets.contains(dpi), presets.count < limit else { return presets }
        return (presets + [dpi]).sorted()
    }

    static func removing(_ dpi: Int, from presets: [Int]) -> [Int] { presets.filter { $0 != dpi } }

    /// The step of `steps` nearest to `dpi` (the sensor's own list; the daemon snaps the same way).
    static func snap(_ dpi: Int, to steps: [Int]) -> Int {
        steps.min { abs($0 - dpi) < abs($1 - dpi) } ?? dpi
    }

    /// The preset after `current`, wrapping, as the `cycleDPI` action picks it.
    static func next(after current: Int, in presets: [Int]) -> Int? {
        guard !presets.isEmpty else { return nil }
        return presets.first { $0 > current } ?? presets[0]
    }
}

enum Format {
    static func dpi(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic)) + " DPI"
    }

    static func number(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }

    static func multiplier(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value * 10 == (value * 10).rounded() ? 1 : 2))) + "×"
    }

    static func millimetres(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " mm"
    }

    static func milliseconds(_ value: Double) -> String { "\(Int(value.rounded())) ms" }

    /// Rounds a slider value to its step, so the config holds 0.75, not 0.7500000001.
    static func snap(_ value: Double, step: Double) -> Double {
        let snapped = (value / step).rounded() * step
        return (snapped * 1000).rounded() / 1000
    }

    static func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
