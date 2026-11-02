import Foundation
import PureMouseKit

/// When to tell the user a mouse battery is running out. Pure logic: the state it keeps per mouse
/// is the most severe band already announced, so one notification fires per downward crossing
/// (through 20%, then through 5%) and a re-read of the same level never repeats it.
public enum BatteryAlert {
    /// The band already announced for a mouse. Ordered: `none` < `low` < `critical`.
    public enum Band: String, Codable, Comparable, CaseIterable, Sendable {
        case none, low, critical

        private var rank: Int { self == .none ? 0 : self == .low ? 1 : 2 }
        public static func < (a: Band, b: Band) -> Bool { a.rank < b.rank }
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

    /// The notification's text: "MX Master 3S battery low" and "20% left. Charge it soon." A mouse
    /// that reports no percentage gets the advice alone.
    public static func message(for band: Band, device: String, battery: Status.Device.Battery) -> (title: String, body: String) {
        let left = battery.percent.map { "\($0)% left. " } ?? ""
        switch band {
        case .critical: return ("\(device) battery critical", left + "Charge it now.")
        default: return ("\(device) battery low", left + "Charge it soon.")
        }
    }
}

/// The announced bands, kept in the companion directory so they outlive this process (it starts
/// over after Settings closes, and a restart must not announce the same crossing again). A mouse
/// that reports a stable identity (its device key and 0x0003 unit ID) is keyed by it, so a
/// reconnect is judged against the band announced before it left; any other is keyed by the
/// daemon's device id (interface plus index), which a reconnect cannot tell from another mouse.
public struct BatteryAlertStore {
    public struct Reading {
        public var id: String
        public var name: String
        public var battery: Status.Device.Battery
        public var model: String?
        public var unit: String?

        public init(id: String, name: String, battery: Status.Device.Battery, model: String? = nil, unit: String? = nil) {
            self.id = id
            self.name = name
            self.battery = battery
            self.model = model
            self.unit = unit
        }

        /// Whether the status names this unit of this model, so it is the same mouse across
        /// reconnects and restarts.
        var hasStableIdentity: Bool { model != nil && unit != nil }

        /// What the band is kept under.
        var key: String {
            guard let model, let unit else { return id }
            return "unit:\(model):\(unit)"
        }
    }

    public struct Alert: Equatable {
        public var key: String
        public var name: String
        public var band: BatteryAlert.Band
        public var battery: Status.Device.Battery

        /// The notification's identifier: stable per mouse and band, so it can be removed later.
        public var notificationID: String { BatteryAlertStore.notificationID(key: key, band: band) }
    }

    /// What to do after one status: notifications to post and delivered ones to take down.
    public struct Outcome: Equatable {
        public var alerts: [Alert] = []
        public var remove: [String] = []
    }

    /// The file's format. A file in any other shape (an older one, a damaged one) is discarded.
    private struct File: Codable {
        static let version = 2
        var version = File.version
        var bands: [String: BatteryAlert.Band]
    }

    var url: URL
    private(set) var bands: [String: BatteryAlert.Band]
    /// Mice seen live in the previous status. One not in it has just connected (or this process
    /// just started): without a stable identity and a recorded band, its first reading only
    /// records, however far it moved while away.
    private var live: Set<String> = []
    /// The setting as of the previous status; nil before the first.
    private var wasEnabled: Bool?

    public init(url: URL) {
        self.url = url
        let file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        bands = file?.version == File.version ? file?.bands ?? [:] : [:]
    }

    static func notificationID(key: String, band: BatteryAlert.Band) -> String { "battery.\(key).\(band.rawValue)" }

    /// Evaluates the live mice of one status (none when the daemon is off); saves only when a
    /// state changed. With `enabled` false the state still advances, so turning it on later does
    /// not announce an old crossing, and every notification this store may have delivered is
    /// taken down once.
    public mutating func process(_ readings: [Reading], enabled: Bool = true) -> Outcome {
        var outcome = Outcome()
        var remove: Set<String> = []
        var changed = false
        if !enabled, wasEnabled != false {
            for (key, band) in bands where band != .none { remove.insert(Self.notificationID(key: key, band: band)) }
        }
        for reading in readings {
            let key = reading.key
            let previous = bands[key]
            let result = BatteryAlert.evaluate(previous: previous, battery: reading.battery)
            // A band left behind (recharged, or recovered a step) no longer holds.
            if let previous {
                for band in BatteryAlert.Band.allCases where band > result.state && band <= previous {
                    remove.insert(Self.notificationID(key: key, band: band))
                }
            }
            if previous != result.state {
                bands[key] = result.state
                changed = true
            }
            guard let band = result.alert else { continue }
            // A deeper band replaces the shallower one.
            for shallower in BatteryAlert.Band.allCases where shallower > .none && shallower < band {
                remove.insert(Self.notificationID(key: key, band: shallower))
            }
            let reconnected = live.contains(key) || (reading.hasStableIdentity && previous != nil)
            if enabled, reconnected {
                outcome.alerts.append(Alert(key: key, name: reading.name, band: band, battery: reading.battery))
            }
        }
        live = Set(readings.map(\.key))
        wasEnabled = enabled
        if changed { save() }
        remove.subtract(outcome.alerts.map(\.notificationID))
        outcome.remove = remove.sorted()
        return outcome
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(File(bands: bands)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
