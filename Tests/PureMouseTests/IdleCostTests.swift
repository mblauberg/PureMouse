import Foundation
import Testing

/// The daemon's idle cost is zero CPU (docs/how-it-works.md, "Threads and idle cost"): nothing in
/// it ticks. Re-checking Logi Options+ and listing a waiting Bluetooth mouse ride the events the
/// daemon already handles (start, wake, reload, a control change, a permission poll), so the daemon
/// owns no timer, and sleeps only where the bounded exceptions are.
@Suite struct IdleCostTests {
    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appending(path: "../../Sources/puremouse").standardized

    private func daemonSources() throws -> [(name: String, text: String)] {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func theDaemonOwnsNoTimer() throws {
        for (name, text) in try daemonSources() {
            for needle in ["Timer(", "scheduledTimer", "makeTimerSource", "CADisplayLink"] {
                #expect(!text.contains(needle), "\(name) uses \(needle)")
            }
        }
    }

    /// A new sleep is a new wait, and a wait that repeats is a poll: add one only as a bounded
    /// exception, in docs/how-it-works.md, and here.
    @Test func sleepsAreOnlyWhereTheBoundedExceptionsAre() throws {
        var sleeping: [String] = []
        for (name, text) in try daemonSources() where text.contains("Task.sleep") { sleeping.append(name) }
        #expect(sleeping.sorted() == ["Daemon.swift", "Probe.swift", "Session.swift", "SessionEnvironment.swift", "main.swift"])
    }
}
