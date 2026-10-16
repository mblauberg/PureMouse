import Foundation
import Testing
@testable import PureMouseKit

@Test func statusRoundTrips() throws {
    let status = Status(
        pid: 42, startedAt: Date(timeIntervalSince1970: 1_800_000_000), version: "0.2.0", running: true,
        paused: false, permissions: .init(accessibility: true, inputMonitoring: false),
        logiOptionsRunning: false, config: .init(path: "/tmp/config.json", error: nil),
        devices: [.init(id: "r1", name: "MX Master 3S", connection: .receiver, online: true,
                        battery: .init(percent: 80, level: .good, charging: false), dpi: 1600,
                        dpiSteps: [200, 250], wheelMode: .ratchet, hasSmartShift: true, hasThumbWheel: true,
                        controls: [.init(cid: 0x53, name: "back")])],
        capture: nil, away: true)
    let data = try Companion.encoder.encode(status)
    #expect(try Companion.decoder.decode(Status.self, from: data) == status)
}

@Test func statusReadsWithoutAway() throws {
    // An older daemon writes no `away`.
    var status = Status(
        pid: 1, startedAt: Date(timeIntervalSince1970: 0), version: "dev", running: true, paused: false,
        permissions: .init(accessibility: true, inputMonitoring: true), logiOptionsRunning: false,
        config: .init(path: "/tmp/c.json", error: nil), devices: [], capture: nil, away: false)
    var json = try JSONSerialization.jsonObject(with: Companion.encoder.encode(status)) as! [String: Any]
    json["away"] = nil
    status.away = nil
    let old = try Companion.decoder.decode(Status.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old == status)
}

@Test func controlReadsWithoutNewerKeys() throws {
    let old = try Companion.decoder.decode(Control.self, from: Data(#"{"paused": true}"#.utf8))
    #expect(old == Control(paused: true))
    let control = Control(paused: false, capture: .init(token: 7), useConfiguredDPI: 9)
    #expect(try Companion.decoder.decode(Control.self, from: Companion.encoder.encode(control)) == control)
}
