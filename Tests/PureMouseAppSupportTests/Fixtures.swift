import Foundation
import PureMouseKit
@testable import PureMouseAppSupport

/// A config file and companion directory in a fresh temporary directory: no bundle and no
/// environment variables.
struct Sandbox {
    let directory: URL
    let locations: Locations

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        locations = Locations(config: directory.appending(path: "config.json"),
                              log: directory.appending(path: "PureMouse.log"),
                              daemon: nil,
                              companion: directory.appending(path: "companion", directoryHint: .isDirectory))
    }

    var config: URL { locations.config }
    var backup: URL { directory.appending(path: "config.json.bak") }

    func write(_ text: String, to url: URL? = nil) throws {
        let url = url ?? config
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL? = nil) throws -> String { String(decoding: try Data(contentsOf: url ?? config), as: UTF8.self) }

    func tree(_ url: URL? = nil) throws -> ConfigTree { try ConfigTree(data: Data(contentsOf: url ?? config)) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func writeStatus(_ status: Status) throws {
        try Companion.write(status, to: locations.status)
    }

    func control() -> Control? { Companion.read(Control.self, from: locations.control) }
}

/// A clock whose delayed work runs only when a test says so.
@MainActor
final class ManualClock {
    private(set) var pending: [(seconds: TimeInterval, work: @MainActor () -> Void, id: Int)] = []
    private var next = 0

    var clock: Clock {
        Clock { [self] seconds, work in
            next += 1
            let id = next
            pending.append((seconds, work, id))
            return { [self] in pending.removeAll { $0.id == id } }
        }
    }

    /// Runs the work due within `seconds`, in order.
    func advance(_ seconds: TimeInterval) {
        let due = pending.filter { $0.seconds <= seconds }
        pending.removeAll { $0.seconds <= seconds }
        for item in due { item.work() }
    }
}

func daemonStatus(pid: Int32 = 4242, running: Bool = true, paused: Bool = false, schema: Int = Status.currentSchema,
                  devices: [Status.Device] = [], capture: Status.Capture? = nil, configError: String? = nil) -> Status {
    var status = Status(pid: pid, startedAt: Date(timeIntervalSince1970: 0), version: "0.3.0", running: running,
                        paused: paused, permissions: .init(accessibility: true, inputMonitoring: true),
                        logiOptionsRunning: false, config: .init(path: "/tmp/config.json", error: configError),
                        devices: devices, capture: capture)
    status.schema = schema
    return status
}
