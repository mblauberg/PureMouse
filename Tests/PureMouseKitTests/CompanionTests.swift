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

@Test func controlOptionalFieldsMayBeOmitted() throws {
    let minimal = try Companion.decoder.decode(Control.self, from: Data(#"{"paused": true}"#.utf8))
    #expect(minimal == Control(paused: true))
    let control = Control(paused: false, capture: .init(token: 7), useConfiguredDPI: 9)
    #expect(try Companion.decoder.decode(Control.self, from: Companion.encoder.encode(control)) == control)
}

// MARK: - Device identity, capabilities and aimed requests

/// A status with every field the current types carry set.
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
    @Test func aStatusWithEveryFieldRoundTrips() throws {
        let status = fullStatus()
        let back = try Companion.decoder.decode(Status.self, from: Companion.encoder.encode(status))
        #expect(back == status)
        #expect(back.devices[0].model == "m4082b0230000" && back.devices[0].unit == "0a1b2c3d")
        #expect(back.devices[0].capabilities?.smoothScroll == false && back.devices[0].controls[1].gestures == false)
        #expect(back.capture?.model == "pb02c")
    }

    @Test func requestsAimedAtOneMouseRoundTrip() throws {
        let control = Control(paused: false, capture: .init(token: 9, device: "m4082b0230000"),
                              useConfiguredDPI: 5, device: "pb02c")
        #expect(try Companion.decoder.decode(Control.self, from: Companion.encoder.encode(control)) == control)
        #expect(Control().device == nil && Control.Capture(token: 1).device == nil)
    }

    @Test func unknownCapabilitiesAreLeftOutOfTheJSONNotNull() throws {
        let capabilities = Status.Device.Capabilities(dpi: true, battery: false)
        let json = try #require(try JSONSerialization.jsonObject(
            with: Companion.encoder.encode(capabilities)) as? [String: Any])
        #expect(Set(json.keys) == ["dpi", "battery"])
        #expect(json["dpi"] as? Bool == true && json["battery"] as? Bool == false)
        let text = String(decoding: try Companion.encoder.encode(capabilities), as: UTF8.self)
        #expect(!text.contains("null") && !text.contains("smartShift") && !text.contains("features"))
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
        #expect(fullStatus().schema == 1)
    }
}

@Test(.enabled(if: Companion.overrideDirectory == nil))
func doorbellsKeepTheirNamesWithoutACompanionDirectory() {
    // Unset leaves the shipped names.
    #expect(Companion.doorbell("io.github.mblauberg.puremouse.status", directory: nil) == "io.github.mblauberg.puremouse.status")
    // This test run has no fixture directory, so the shipped names are the plain ones.
    #expect(Companion.statusNotification == "io.github.mblauberg.puremouse.status")
    #expect(Companion.controlNotification == "io.github.mblauberg.puremouse.control")
    #expect(Companion.showSettingsNotification == "io.github.mblauberg.puremouse.menu.show")
}

private let bells = [
    "io.github.mblauberg.puremouse.status",
    "io.github.mblauberg.puremouse.control",
    "io.github.mblauberg.puremouse.menu.show",
]

@Test func doorbellsDifferPerCompanionDirectory() {
    var seen = Set<String>()
    for base in bells {
        let a = Companion.doorbell(base, directory: "/tmp/rig-a")
        #expect(a != base)
        #expect(a.hasPrefix(base + "."))
        #expect(a == Companion.doorbell(base, directory: "/tmp/rig-a")) // the daemon and the menu agree
        #expect(a != Companion.doorbell(base, directory: "/tmp/rig-b"))
        seen.insert(a)
    }
    #expect(seen.count == bells.count)
}

@Test func doorbellsIgnoreHowADirectoryIsSpelled() throws {
    let directory = "/tmp/puremouse-bell-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    for base in bells {
        let expected = Companion.doorbell(base, directory: directory)
        #expect(Companion.doorbell(base, directory: directory + "/") == expected)
        #expect(Companion.doorbell(base, directory: "/private" + directory) == expected)
        #expect(Companion.doorbell(base, directory: directory + "/./") == expected)
    }
}

@Test func doorbellHashIsStable() {
    // Fixed values pin the hash (FNV-1a, 32 bits): it must not change between builds or processes.
    #expect(Companion.fnv1a("") == "811c9dc5")
    #expect(Companion.fnv1a("a") == "e40c292c")
    #expect(Companion.fnv1a("foobar") == "bf9cf968")

// MARK: - Login status

@Test func loginStatusDecodesWhatTheCLIPrints() throws {
    let printed = #"{"service":"launchd","daemon":"enabled","menu":"notRegistered","hidden":false}"#
    let status = try #require(LoginStatus.parse(printed))
    #expect(status == LoginStatus(service: "launchd", daemon: .enabled, menu: .notRegistered, hidden: false))
    #expect(status.startsAtLogin)
    // One line, keys sorted, and it reads back as the same value.
    let json = try status.json()
    #expect(json == #"{"daemon":"enabled","hidden":false,"menu":"notRegistered","service":"launchd"}"#)
    #expect(LoginStatus.parse(json) == status)
}

@Test func loginStatusKnowsEveryJobState() throws {
    for state in ["notRegistered", "enabled", "requiresApproval", "notFound"] {
        let status = try #require(LoginStatus.parse(#"{"service":"x","daemon":"\#(state)","menu":"\#(state)","hidden":true}"#))
        #expect(status.daemon.rawValue == state)
        #expect(status.startsAtLogin == (state == "enabled"))
    }
}

@Test func loginStatusRejectsAnythingElse() {
    #expect(LoginStatus.parse("") == nil)
    #expect(LoginStatus.parse("cannot register: no") == nil)
    #expect(LoginStatus.parse(#"{"service":"launchd","daemon":"maybe","menu":"enabled","hidden":false}"#) == nil)
}
