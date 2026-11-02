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

// MARK: - Additive contract (docs/companion.md, Versioning)

/// A `status.json` as the 0.3.0 daemon wrote it: none of the identity, capability or request fields.
private let status030JSON = """
    {
      "away" : false,
      "capture" : { "cid" : 253, "deviceID" : "1-1", "state" : "pressed", "token" : 3 },
      "config" : { "path" : "/Users/someone/.config/puremouse/config.json" },
      "devices" : [
        {
          "battery" : { "charging" : false, "level" : "good", "percent" : 80 },
          "connection" : "receiver",
          "controls" : [ { "cid" : 83, "name" : "back" }, { "cid" : 253 } ],
          "dpi" : 1600,
          "dpiSteps" : [ 200, 250, 300 ],
          "hasSmartShift" : true,
          "hasThumbWheel" : true,
          "id" : "1-1",
          "name" : "MX Master 3S",
          "online" : true,
          "wheelMode" : "ratchet"
        }
      ],
      "logiOptionsRunning" : false,
      "paused" : false,
      "permissions" : { "accessibility" : true, "inputMonitoring" : true },
      "pid" : 4242,
      "running" : true,
      "schema" : 1,
      "startedAt" : "2026-10-01T09:30:00Z",
      "version" : "0.3.0"
    }
    """

/// A status with every field the current types carry set, new ones included.
private func fullStatus() -> Status {
    Status(
        pid: 7, startedAt: Date(timeIntervalSince1970: 1_800_000_000), version: "0.4.0", running: true,
        paused: false, permissions: .init(accessibility: true, inputMonitoring: true),
        logiOptionsRunning: false, config: .init(path: "/tmp/c.json", error: nil),
        devices: [
            .init(id: "1-1", name: "MX Master 3S", connection: .receiver, online: true,
                  battery: .init(percent: 80, level: .good, charging: false), dpi: 1600, dpiSteps: [200, 250],
                  wheelMode: .ratchet, hasSmartShift: true, hasThumbWheel: true,
                  controls: [.init(cid: 0x53, name: "back", gestures: true), .init(cid: 0xFD, name: nil, gestures: false)],
                  model: "m4082b0230000", unit: "0a1b2c3d", kind: "mouse",
                  capabilities: .init(dpi: true, smartShift: true, smoothScroll: false, thumbWheel: true,
                                      haptics: false, battery: true, features: ["0001", "2201", "2110"])),
            .init(id: "2-1", name: "M750", connection: .bluetooth, online: true, battery: nil, dpi: nil,
                  dpiSteps: [], wheelMode: nil, hasSmartShift: false, hasThumbWheel: false, controls: [],
                  model: "pb02c", kind: "mouse"),
        ],
        capture: .init(token: 4, state: .pressed, cid: 0xFD, deviceID: "2-1", model: "pb02c"), away: false)
}

@Suite struct CompanionContractTests {
    @Test func aStatusWrittenBy030DecodesWithEveryNewFieldNil() throws {
        let status = try Companion.decoder.decode(Status.self, from: Data(status030JSON.utf8))
        #expect(status.schema == 1 && status.version == "0.3.0")
        let device = try #require(status.devices.first)
        #expect(device.model == nil && device.unit == nil && device.kind == nil && device.capabilities == nil)
        #expect(device.controls.map(\.gestures) == [nil, nil])
        #expect(device.controls.map(\.cid) == [83, 253] && device.name == "MX Master 3S")
        #expect(status.capture?.model == nil && status.capture?.cid == 253)
        // The fixture is a real 0.3.0 file: the frozen types read it too.
        let frozen = try Companion.decoder.decode(Status030.self, from: Data(status030JSON.utf8))
        #expect(frozen.devices.first?.dpiSteps == device.dpiSteps)
    }

    @Test func aStatus030FileRoundTripsWithoutGainingFields() throws {
        let status = try Companion.decoder.decode(Status.self, from: Data(status030JSON.utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: Companion.encoder.encode(status)) as? [String: Any])
        let device = try #require((json["devices"] as? [[String: Any]])?.first)
        for key in ["model", "unit", "kind", "capabilities"] { #expect(device[key] == nil, "\(key)") }
        let control = try #require((device["controls"] as? [[String: Any]])?.last)
        #expect(control["gestures"] == nil && control["name"] == nil)
    }

    @Test func the030TypesDecodeEverythingTheNewDaemonWrites() throws {
        let status = fullStatus()
        let data = try Companion.encoder.encode(status)
        let frozen = try Companion.decoder.decode(Status030.self, from: data)
        #expect(frozen.schema == 1 && frozen.devices.count == 2 && frozen.devices[0].controls.count == 2)
        #expect(frozen.capture?.cid == 0xFD && frozen.capture?.deviceID == "2-1")
        // And the current types read it back whole.
        #expect(try Companion.decoder.decode(Status.self, from: data) == status)
    }

    /// Every case of each enum the 0.3.0 reader decodes strictly. The switches have no `default`,
    /// so adding a case to one of these enums stops compiling here until the case is listed and
    /// the frozen reader has been checked against it (rule 3 of the additive contract).
    @Test func the030TypesDecodeEveryCaseOfEveryStatusEnum() throws {
        func connections(_ c: Status.Device.Connection) -> [Status.Device.Connection] {
            switch c { case .receiver, .bluetooth: [.receiver, .bluetooth] }
        }
        func wheelModes(_ m: Status.Device.WheelMode) -> [Status.Device.WheelMode] {
            switch m { case .ratchet, .freespin: [.ratchet, .freespin] }
        }
        func levels(_ l: Status.Device.Battery.Level) -> [Status.Device.Battery.Level] {
            switch l { case .full, .good, .low, .critical: [.full, .good, .low, .critical] }
        }
        func states(_ s: Status.Capture.State) -> [Status.Capture.State] {
            switch s { case .listening, .pressed, .timedOut, .cancelled: [.listening, .pressed, .timedOut, .cancelled] }
        }
        let every = (connections(.receiver), wheelModes(.ratchet), levels(.full), states(.listening))
        #expect(every.0.count == 2 && every.1.count == 2 && every.2.count == 4 && every.3.count == 4)

        var seen = 0
        for connection in every.0 {
            for mode in every.1 {
                for level in every.2 {
                    var status = fullStatus()
                    status.devices[0].connection = connection
                    status.devices[0].wheelMode = mode
                    status.devices[0].battery = .init(percent: 50, level: level, charging: false)
                    let frozen = try Companion.decoder.decode(Status030.self, from: Companion.encoder.encode(status))
                    #expect(frozen.devices[0].connection.rawValue == connection.rawValue)
                    #expect(frozen.devices[0].wheelMode?.rawValue == mode.rawValue)
                    #expect(frozen.devices[0].battery?.level.rawValue == level.rawValue)
                    seen += 1
                }
            }
        }
        #expect(seen == 2 * 2 * 4)
        for state in every.3 {
            var status = fullStatus()
            status.capture = .init(token: 1, state: state, cid: nil, deviceID: nil)
            let frozen = try Companion.decoder.decode(Status030.self, from: Companion.encoder.encode(status))
            #expect(frozen.capture?.state.rawValue == state.rawValue)
        }
    }

    @Test func the030ControlDecodesTheNewRequestFields() throws {
        let control = Control(paused: false, capture: .init(token: 9, device: "m4082b0230000"),
                              useConfiguredDPI: 5, device: "pb02c")
        let data = try Companion.encoder.encode(control)
        let frozen = try Companion.decoder.decode(Control030.self, from: data)
        #expect(frozen.paused == false && frozen.capture?.token == 9 && frozen.useConfiguredDPI == 5)
        #expect(try Companion.decoder.decode(Control.self, from: data) == control)
        // A control written by 0.3.0 has none of them.
        let old = try Companion.decoder.decode(Control.self, from: Data(#"{"paused": false, "capture": {"token": 1}}"#.utf8))
        #expect(old.device == nil && old.capture?.device == nil)
    }

    @Test func unknownCapabilitiesAreLeftOutOfTheJSONNotNull() throws {
        let capabilities = Status.Device.Capabilities(dpi: true, battery: false)
        let json = try #require(try JSONSerialization.jsonObject(
            with: Companion.encoder.encode(capabilities)) as? [String: Any])
        #expect(Set(json.keys) == ["dpi", "battery"])
        #expect(json["dpi"] as? Bool == true && json["battery"] as? Bool == false)
        let text = String(decoding: try Companion.encoder.encode(capabilities), as: UTF8.self)
        #expect(!text.contains("null") && !text.contains("smartShift") && !text.contains("features"))
        #expect(try Companion.encoder.encode(Status.Device.Capabilities()) == Data("{\n\n}".utf8))
        // Read back, the missing members are unknown.
        let back = try Companion.decoder.decode(Status.Device.Capabilities.self, from: Data(#"{"dpi": true}"#.utf8))
        #expect(back.smartShift == nil && back.features == nil)
    }

    @Test func nilIdentityFieldsAreLeftOutOfADeviceToo() throws {
        let device = Status.Device(id: "1", name: "x", connection: .receiver, online: true, battery: nil, dpi: nil,
                                   dpiSteps: [], wheelMode: nil, hasSmartShift: false, hasThumbWheel: false,
                                   controls: [.init(cid: 1, name: nil)])
        let text = String(decoding: try Companion.encoder.encode(device), as: UTF8.self)
        for key in ["model", "unit", "kind", "capabilities", "gestures"] { #expect(!text.contains(key), "\(key)") }
    }

    @Test func theSchemaIsStillOne() {
        #expect(Status.currentSchema == 1)
        #expect(Status030.currentSchema == 1)
        #expect(fullStatus().schema == 1)
    }
}
