import Foundation
import HIDPP

/// Stateful HID++ responder. Probe dumps describe the feature table and initial readbacks;
/// writes update those same readbacks, so tests can assert device state rather than call lists.
@MainActor
public final class FakeDevice {
    public enum Ping { case hidpp20(UInt8, UInt8), hidpp10(UInt8), silent }
    public enum Failure { case error(UInt8), timeout, sendFailed(Int32) }
    public struct Call: Hashable {
        public let feature: UInt16
        public let function: UInt8
        public init(_ feature: UInt16, _ function: UInt8) { self.feature = feature; self.function = function }
    }
    public struct Control: Equatable {
        public var info: [UInt8]
        public var reporting: [UInt8]
        public var cid: UInt16 { UInt16(info[0]) << 8 | UInt16(info[1]) }
        public var diverted: Bool { reporting[2] & 1 != 0 }
        public var persistent: Bool { reporting[2] & 4 != 0 }
        public var rawXY: Bool { reporting[2] & 0x10 != 0 }
        public init(cid: UInt16, flags: UInt8 = 0x20, additionalFlags: UInt8 = 1,
                    diverted: Bool = false, persistent: Bool = false) {
            info = [UInt8(cid >> 8), UInt8(cid & 0xFF), 0, 0, flags, 0, 0, 0, additionalFlags]
            reporting = [info[0], info[1], (diverted ? 1 : 0) | (persistent ? 4 : 0), 0, 0, 0]
        }
    }

    public private(set) var transport: FakeTransport
    /// The device index it answers at: `directDeviceIndex`, or its receiver slot (`onReceiver`).
    public private(set) var index = directDeviceIndex
    public var name: String
    public var ping: Ping = .hidpp20(4, 5)
    public var features: [UInt8: UInt16]
    public var controls: [Control] = []
    public var responses: [Call: [UInt8]] = [:]
    /// A failure remains until removed; useful for retry and offline tests.
    public var failures: [Call: Failure] = [:]
    public var playedWaveforms: [UInt8] = []
    /// A mouse in onboard-profile mode (0x8100) can acknowledge a DPI write and keep its own
    /// resolution; the readback then shows the old value.
    public var ignoresDPIWrites = false
    /// Like `ignoresDPIWrites`, for the Y axis of 0x2202 alone: X is taken, Y keeps its value.
    public var ignoresDPIYWrites = false
    /// A 0x2130 reporting write is acknowledged and not taken, so the byte reads back as before.
    public var ignoresLowResWheelWrites = false
    /// The words of 0x2202's DPI list per direction (0 X, 1 Y), terminator included, served 13
    /// bytes to a reply behind a three-byte header, as the page index asks. A direction without
    /// one gets the single reply of `responses` or the default.
    public var extendedDPILists: [UInt8: [UInt8]] = [:]
    /// getDeviceType's answer (0x0005 function 2): 3 is a mouse.
    public var kind: UInt8 = 3
    /// Features whose next root lookup goes unanswered (`dropFirstLookup`), and those dropped.
    private var lookupsToDrop: Set<UInt16> = []
    public private(set) var droppedLookups: Set<UInt16> = []

    public init(name: String = "Fake mouse", features: [UInt8: UInt16] = [:]) {
        self.name = name
        self.features = features
        transport = FakeTransport(product: name)
        transport.answer = { [weak self] in try self?.answer($0) }
    }

    /// Puts the mouse in `slot` of a receiver, on a transport of its own; before any endpoint.
    public func onReceiver(slot: UInt8) {
        transport = FakeTransport(product: "Fake receiver", productID: 0xC548, isReceiver: true)
        transport.answer = { [weak self] in try self?.answer($0) }
        index = slot
    }

    /// The receiver's connection notification (0x41) for the slot: `product` linked up or down.
    public func announce(product: UInt16, linked: Bool = true) {
        transport.deliver(Report(bytes: [0x10, index, 0x41, 0x10, linked ? 0 : 0x40,
                                         UInt8(product & 0xFF), UInt8(product >> 8)])!)
    }

    public func endpoint(softwareIDs: ClosedRange<UInt8> = HIDPPDevice.defaultSoftwareIDs) -> HIDPPDevice {
        HIDPPDevice(interface: transport, index: index, softwareIDs: softwareIDs)
    }

    public var mainWheelDiverted: Bool { (responses[Call(0x2121, 1)]?.first ?? 0) & 1 != 0 }
    public var mainWheelHighResolution: Bool { (responses[Call(0x2121, 1)]?.first ?? 0) & 2 != 0 }
    public var lowResWheelDiverted: Bool { (responses[Call(0x2130, 0)]?.first ?? 0) & 1 != 0 }
    public var thumbWheelDiverted: Bool { (responses[Call(0x2150, 1)]?.first ?? 0) & 1 != 0 }
    /// The resolution the sensor reads back: 0x2201's, or 0x2202's X axis where there is no 0x2201.
    public var dpi: Int {
        let extended = !features.values.contains(0x2201) && features.values.contains(0x2202)
        let r = extended ? responses[Call(0x2202, 5)] ?? Self.defaults[Call(0x2202, 5)]!
                         : responses[Call(0x2201, 2)] ?? [0, 3, 232]
        return Int(UInt16(r[1]) << 8 | UInt16(r[2]))
    }

    public func emit(_ feature: UInt16, function: UInt8 = 0, params: [UInt8]) {
        guard let index = features.first(where: { $0.value == feature })?.key else { return }
        transport.deliver(Report(deviceIndex: self.index, featureIndex: index,
                                 function: function, softwareID: 0, params: params))
    }

    public func feature(of request: Report) -> UInt16? { request.featureIndex == 0 ? 0 : features[request.featureIndex] }

    /// Requests sent so far to `feature`'s `function`.
    public func requests(feature: UInt16, function: UInt8) -> [Report] {
        transport.sent.filter { self.feature(of: $0) == feature && $0.function == function }
    }

    /// setCidReporting (0x1B04 function 3) requests sent so far for `cid`.
    public func controlWrites(cid: UInt16) -> [Report] {
        requests(feature: 0x1B04, function: 3).filter {
            $0.params.count >= 2 && UInt16($0.params[0]) << 8 | UInt16($0.params[1]) == cid
        }
    }

    public func control(_ cid: UInt16) -> Control? { controls.first { $0.cid == cid } }

    /// Every control back to native reporting, as a mouse comes up: for a dump taken while
    /// another program had diverted some.
    public func resetReporting() {
        for control in controls { setReporting(control.cid) }
    }

    /// Sets the reporting flags `cid` reads back with, as left by another program or process.
    public func setReporting(_ cid: UInt16, diverted: Bool = false, persistent: Bool = false, rawXY: Bool = false) {
        guard let i = controls.firstIndex(where: { $0.cid == cid }) else { preconditionFailure("no control \(cid)") }
        controls[i].reporting[2] = (diverted ? 1 : 0) | (persistent ? 4 : 0) | (rawXY ? 0x10 : 0)
    }

    /// The next root lookup of `feature` goes unanswered, as a request lost to a busy receiver
    /// does; the ones after it are answered. Recorded in `droppedLookups` once dropped.
    public func dropFirstLookup(of feature: UInt16) {
        lookupsToDrop.insert(feature)
    }

    private func answer(_ r: Report) throws -> Report? {
        let feature = feature(of: r) ?? 0xFFFF
        if let failure = failures[Call(feature, r.function)] {
            switch failure {
            case .error(let code): return FakeTransport.error(to: r, code: code)
            case .timeout: return nil
            case .sendFailed(let code): throw HIDPPError.sendFailed(code)
            }
        }
        func reply(_ params: [UInt8]) -> Report { FakeTransport.reply(to: r, params: params) }
        let p = r.params
        if feature == 0 {
            if r.function == 1 {
                switch ping {
                case .hidpp20(let major, let minor): return reply([major, minor, 0x5A])
                case .hidpp10(let code): return FakeTransport.error(to: r, code: code, legacy: true)
                case .silent: return nil
                }
            }
            guard p.count >= 2 else { return FakeTransport.error(to: r, code: 2) }
            let id = UInt16(p[0]) << 8 | UInt16(p[1])
            if r.function == 0, lookupsToDrop.remove(id) != nil {
                droppedLookups.insert(id)
                return nil
            }
            return reply([features.first { $0.value == id }?.key ?? 0])
        }
        switch (feature, r.function) {
        case (0x0001, 0): return reply(responses[Call(0x0001, 0)] ?? [UInt8(features.count)])
        case (0x0001, 1):
            guard let index = p.first, let id = features[index] else { return FakeTransport.error(to: r, code: 2) }
            return reply([UInt8(id >> 8), UInt8(id & 0xFF)])
        case (0x0005, 0): return reply([UInt8(name.utf8.count)])
        case (0x0005, 1): return reply(Array(name.utf8.dropFirst(Int(p.first ?? 0)).prefix(16)))
        case (0x0005, 2): return reply([kind])
        case (0x1B04, 0): return reply([UInt8(controls.count)])
        case (0x1B04, 1):
            guard let i = p.first, Int(i) < controls.count else { return FakeTransport.error(to: r, code: 2) }
            return reply(controls[Int(i)].info)
        case (0x1B04, 2), (0x1B04, 3):
            guard p.count >= 2, let i = controls.firstIndex(where: { $0.cid == UInt16(p[0]) << 8 | UInt16(p[1]) })
            else { return FakeTransport.error(to: r, code: 2) }
            if r.function == 3, p.count >= 3 {
                // Respect valid bits; persistent diversion is deliberately never written by PureMouse.
                if p[2] & 2 != 0 { controls[i].reporting[2] = (controls[i].reporting[2] & ~1) | (p[2] & 1) }
                if p[2] & 0x20 != 0 { controls[i].reporting[2] = (controls[i].reporting[2] & ~0x10) | (p[2] & 0x10) }
            }
            return reply(controls[i].reporting)
        case (0x2121, 2): responses[Call(feature, 1)] = p; return reply(p)
        case (0x2150, 2): responses[Call(feature, 1)] = p; return reply(p)
        case (0x2130, 1):
            if !ignoresLowResWheelWrites { responses[Call(feature, 0)] = p }
            return reply(p)
        case (0x2201, 3):
            if !ignoresDPIWrites { responses[Call(feature, 2)] = p }
            return reply(p)
        case (0x2202, 2) where r.params.count >= 3 && extendedDPILists[r.params[1]] != nil:
            let words = extendedDPILists[r.params[1]]!, page = Int(r.params[2])
            let chunk = words.dropFirst(page * 13).prefix(13)
            return reply(Array(r.params.prefix(3)) + chunk + Array(repeating: 0, count: 13 - chunk.count))
        case (0x2202, 6):
            // [sensor, X, Y, lift-off distance] in; [sensor, X, default X, Y, default Y, lift-off] out.
            guard p.count >= 6 else { return FakeTransport.error(to: r, code: 2) }
            let old = responses[Call(feature, 5)] ?? Self.defaults[Call(feature, 5)]!
            if !ignoresDPIWrites {
                let y = ignoresDPIYWrites ? [old[5], old[6]] : [p[3], p[4]]
                responses[Call(feature, 5)] = [p[0], p[1], p[2], old[3], old[4], y[0], y[1], old[7], old[8], p[5]]
            }
            return reply(p)
        case (0x2110, 1), (0x2111, 2):
            let getter: UInt8 = feature == 0x2110 ? 0 : 1
            var state = responses[Call(feature, getter)] ?? [2, 30, 50]
            for i in 0..<min(state.count, p.count) where p[i] != 0 { state[i] = p[i] }
            responses[Call(feature, getter)] = state
            return reply(state)
        case (0x19B0, 4): playedWaveforms.append(p[0]); return reply([])
        default:
            if let response = responses[Call(feature, r.function)] { return reply(response) }
            if let response = Self.defaults[Call(feature, r.function)] { return reply(response) }
            if feature == 0x0003 { return reply(Array(repeating: 0, count: 16)) }
            if feature == 0x1D4B { return reply([0, 0, 0]) }
            return FakeTransport.error(to: r, code: 2)
        }
    }

    /// Parse the diagnostic's line format, ignoring headings and unsupported-feature errors.
    public static func probe(_ text: String) -> FakeDevice {
        let fake = FakeDevice()
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("== "), let pid = line.split(separator: " ").first(where: { $0.hasPrefix("pid=0x") }),
               let id = Int(pid.dropFirst(6), radix: 16) {
                fake.transport.productID = id
            }
            if line.hasPrefix("name: ") { fake.name = String(line.dropFirst(6)) }
            if line.hasPrefix("type: "),
               let kind = DeviceName.Kind.allCases.first(where: { $0.name == line.dropFirst(6) }) {
                fake.kind = kind.rawValue
            }
            if line.hasPrefix("device product IDs: ") {
                let pairs = line.dropFirst(20).split(separator: " ").map { $0.split(separator: "=") }
                var reply = Array(repeating: UInt8(0), count: 16)
                var offset = 7
                for transport in DeviceIdentity.Transport.allCases {
                    guard offset + 1 < 13,
                          let pair = pairs.first(where: { $0.count == 2 && $0[0] == String(describing: transport) }),
                          let id = UInt16(pair[1].dropFirst(2), radix: 16) else { continue }
                    reply[6] |= transport.rawValue
                    reply[offset] = UInt8(id >> 8)
                    reply[offset + 1] = UInt8(id & 0xFF)
                    offset += 2
                }
                fake.responses[Call(0x0003, 0)] = reply
            }
            if line.hasPrefix("features: ") {
                for word in line.dropFirst(10).split(separator: " ") {
                    let pair = word.split(separator: ":")
                    if pair.count == 2, let index = UInt8(pair[0], radix: 16), let id = UInt16(pair[1], radix: 16) {
                        fake.features[index] = id
                    }
                }
            }
            if let infoRange = line.range(of: " info="), let reportingRange = line.range(of: " reporting=") {
                let info = hex(String(line[infoRange.upperBound..<reportingRange.lowerBound]))
                let reporting = hex(String(line[reportingRange.upperBound...]))
                if info.count >= 9, reporting.count >= 3 {
                    var control = Control(cid: UInt16(info[0]) << 8 | UInt16(info[1]))
                    control.info = info
                    control.reporting = reporting + Array(repeating: 0, count: max(0, 6 - reporting.count))
                    fake.controls.append(control)
                }
            }
            for (label, call) in probeCalls {
                let prefix = label + ": "
                if line.hasPrefix(prefix) {
                    let bytes = hex(String(line.dropFirst(prefix.count)))
                    if !bytes.isEmpty { fake.responses[call] = bytes }
                }
            }
        }
        return fake
    }

    private static func hex(_ string: String) -> [UInt8] {
        let words = string.split(separator: " ")
        guard words.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { return [] }
        return words.compactMap { UInt8($0, radix: 16) }
    }

    private static let probeCalls: [(String, Call)] = [
        ("smartshift 0x2110 get", Call(0x2110, 0)), ("smartshift 0x2111 caps", Call(0x2111, 0)),
        ("smartshift 0x2111 get", Call(0x2111, 1)), ("dpi 0x2201 sensors", Call(0x2201, 0)),
        ("dpi 0x2201 list", Call(0x2201, 1)), ("dpi 0x2201 get", Call(0x2201, 2)),
        ("hires 0x2121 caps", Call(0x2121, 0)), ("hires 0x2121 mode", Call(0x2121, 1)),
        ("thumb 0x2150 info", Call(0x2150, 0)), ("thumb 0x2150 status", Call(0x2150, 1)),
        ("battery 0x1004 status", Call(0x1004, 1)), ("battery 0x1000 status", Call(0x1000, 0)),
        ("battery 0x1001 voltage", Call(0x1001, 0)), ("lowres 0x2130 mode", Call(0x2130, 0)),
        ("dpi 0x2202 caps", Call(0x2202, 1)), ("dpi 0x2202 list", Call(0x2202, 2)),
        ("dpi 0x2202 get", Call(0x2202, 5)),
        ("haptic 0x19B0 caps", Call(0x19B0, 0)),
    ]

    private static let defaults: [Call: [UInt8]] = [
        Call(0x2110, 0): [2, 30], Call(0x2111, 0): [1, 50], Call(0x2111, 1): [2, 30, 50],
        Call(0x2201, 0): [1], Call(0x2201, 1): [0, 0, 200, 0xE0, 50, 0x1F, 0x40, 0, 0],
        Call(0x2201, 2): [0, 3, 232], Call(0x2121, 0): [15], Call(0x2121, 1): [0],
        Call(0x2150, 0): [0, 18, 0, 120], Call(0x2150, 1): [0, 0],
        Call(0x1004, 0): [15, 3], Call(0x1004, 1): [80, 4, 0, 0], Call(0x1000, 0): [80, 20, 0],
        Call(0x19B0, 0): [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF],
        // Native reporting; 4088 mV discharging (OpenLogi's G915); 0x2202 as Solaar lays it out:
        // separate Y and lift-off distance, 100 to 25600 step 50, 800 DPI on both axes, high lift-off.
        Call(0x2130, 0): [0], Call(0x1001, 0): [0x0F, 0xF8, 0],
        Call(0x2202, 1): [0, 0, 3],
        Call(0x2202, 2): [0, 0, 0, 0x00, 0x64, 0xE0, 0x32, 0x64, 0x00, 0, 0],
        Call(0x2202, 5): [0, 0x03, 0x20, 0x03, 0x20, 0x03, 0x20, 0x03, 0x20, 2],
    ]
}
