import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseMenu

/// `AppController` built over a sandbox, with spies where it would reach the notification centre:
/// a run with its icon hidden must not announce, withdraw, consume a band or ask for permission.
@MainActor
struct AppControllerNotificationDeliveryTests {
    private final class Spy {
        var announced: [String] = []
        var withdrawn: [[String]] = []
        var permissionRequests = 0
    }

    private let directory: URL
    private let locations: Locations
    private let spy = Spy()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pm-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        locations = Locations(config: directory.appending(path: "config.json"),
                              log: directory.appending(path: "PureMouse.log"), daemon: nil,
                              companion: directory.appending(path: "companion", directoryHint: .isDirectory))
    }

    private func controller(iconShown: Bool) -> AppController {
        AppController(locations: locations, iconShown: iconShown,
                      announce: { [spy] id, _, _ in spy.announced.append(id) },
                      withdraw: { [spy] ids in spy.withdrawn.append(ids) },
                      requestPermission: { [spy] in spy.permissionRequests += 1 })
    }

    private func writeConfig(lowBattery: Bool) throws {
        try Data(#"{"notifications": {"lowBattery": \#(lowBattery)}}"#.utf8).write(to: locations.config)
    }

    private func writeStatus(percent: Int) throws {
        let device = Status.Device(id: "r1:1", name: "MX", connection: .receiver, online: true,
                                   battery: .init(percent: percent, level: .good, charging: false),
                                   dpi: nil, dpiSteps: [], wheelMode: nil, controls: [],
                                   model: "m000000000001", unit: "0a1b2c3d")
        let status = Status(pid: getpid(), startedAt: Date(timeIntervalSince1970: 0), version: "0.3.0", running: true,
                            paused: false, permissions: .init(accessibility: true, inputMonitoring: true),
                            logiOptionsRunning: false, config: .init(path: locations.config.path, error: nil),
                            devices: [device], capture: nil)
        try Companion.write(status, to: locations.status)
    }

    /// The mouse was at 60% when the app last ran, and has drained to 15% since.
    private func drainedWhileAway(_ controller: () -> AppController) throws {
        try writeStatus(percent: 60)
        let first = controller()
        first.model.reloadStatus()
        try writeStatus(percent: 15)
        controller().model.reloadStatus()
    }

    @Test func aRunWithTheIconShownAnnouncesAReconnectCrossing() throws {
        try drainedWhileAway { controller(iconShown: true) }
        #expect(spy.announced == ["battery.unit:m000000000001:0a1b2c3d.low"])
    }

    @Test func aRunWithTheIconHiddenNeitherAnnouncesNorConsumesTheCrossing() throws {
        try drainedWhileAway { controller(iconShown: false) }
        #expect(spy.announced.isEmpty && spy.withdrawn.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: locations.batteryAlerts.path))
        // The next run with the icon shown still warns once.
        try writeStatus(percent: 60)
        controller(iconShown: true).model.reloadStatus()
        try writeStatus(percent: 15)
        controller(iconShown: true).model.reloadStatus()
        #expect(spy.announced == ["battery.unit:m000000000001:0a1b2c3d.low"])
    }

    @Test func switchingTheSettingOnAsksForPermissionOnlyWhenTheIconIsShown() throws {
        for shown in [true, false] {
            try writeConfig(lowBattery: false)
            let controller = controller(iconShown: shown)
            try writeConfig(lowBattery: true)
            controller.model.reloadConfig()
            controller.statusChanged()
            #expect(spy.permissionRequests == (shown ? 1 : 0), "shown: \(shown)")
            spy.permissionRequests = 0
        }
    }
}
