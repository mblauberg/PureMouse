import Foundation
import PureMouseKit

/// When to tell the user a mouse battery is running out. Pure logic: the state it keeps per mouse
/// is the most severe band already announced, so one notification fires per downward crossing
/// (through 20%, then through 5%) and a re-read of the same level never repeats it.
enum BatteryAlert {
    /// The band already announced for a mouse. Ordered: `none` < `low` < `critical`.
    enum Band: String, Codable, Comparable, Sendable {
        case none, low, critical

        private var rank: Int { self == .none ? 0 : self == .low ? 1 : 2 }
        static func < (a: Band, b: Band) -> Bool { a.rank < b.rank }
    }

    static let lowPercent = 20
    static let criticalPercent = 5
    /// A band is left again only this far above its edge, so a reading hovering at 20% does not
    /// notify on every dip.
    static let hysteresis = 5

    /// The notification to post, if any, and the state to keep. `previous` is nil the first time
    /// this mouse is seen: that reading sets the state and never notifies.
    static func evaluate(previous: Band?, battery: Status.Device.Battery) -> (alert: Band?, state: Band) {
        if battery.charging { return (nil, .none) }
        let percent = effectivePercent(battery)
        guard let previous else { return (nil, band(at: percent)) }
        var state = previous
        // Rising: leave a band only once clear of its edge plus the hysteresis.
        if percent >= lowPercent + hysteresis {
            state = .none
        } else if state == .critical, percent >= criticalPercent + hysteresis {
            state = .low
        }
        // Falling: announce each deeper band once.
        let reached = band(at: percent)
        if reached > state { return (reached, reached) }
        return (nil, state)
    }

    /// Level-only mice report no percentage: their low and critical levels stand at the edges.
    static func effectivePercent(_ battery: Status.Device.Battery) -> Int {
        if let percent = battery.percent { return percent }
        switch battery.level {
        case .critical: return criticalPercent
        case .low: return lowPercent
        case .good, .full: return 100
        }
    }

    static func band(at percent: Int) -> Band {
        percent <= criticalPercent ? .critical : percent <= lowPercent ? .low : .none
    }

    static func message(for band: Band, device: String, battery: Status.Device.Battery) -> (title: String, body: String) {
        let detail = battery.percent.map { "\(device) is at \($0)%." } ?? "\(device)'s battery is \(band == .critical ? "critical" : "low")."
        switch band {
        case .critical: return ("Mouse battery critical", detail + " Charge it now.")
        default: return ("Mouse battery low", detail + " Charge it soon.")
        }
    }
}

/// The announced bands, kept in the companion directory so they outlive this process (it starts
/// over after Settings closes, and a restart must not announce the same crossing again).
struct BatteryAlertStore {
    var url: URL
    private(set) var bands: [String: BatteryAlert.Band]

    init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        bands = data.flatMap { try? JSONDecoder().decode([String: BatteryAlert.Band].self, from: $0) } ?? [:]
    }

    /// Evaluates one reading; saves only when the state changed.
    mutating func process(device: String, battery: Status.Device.Battery) -> BatteryAlert.Band? {
        let result = BatteryAlert.evaluate(previous: bands[device], battery: battery)
        if bands[device] != result.state {
            bands[device] = result.state
            save()
        }
        return result.alert
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bands) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
