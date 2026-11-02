import Dispatch
import Foundation
import PureMouseKit
import Testing
@testable import puremouse

@MainActor @Suite struct ClearControlTests {
    /// The menu read `control.json` and is mid-write under `control.json.lock` as the daemon starts.
    /// The daemon's delete waits for that write, then removes it, so no state read from the old
    /// file is written back after the clear.
    @Test func theStartupClearWaitsForAWriteInProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClearControlTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appending(path: "control.json")
        try Data(#"{"paused":true}"#.utf8).write(to: control)

        let locked = DispatchSemaphore(value: 0)
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? FileLock.withLock(FileLock.url(for: control)) {
                locked.signal()
                // Long enough for an unlocked delete to run first and this write to land after it.
                Thread.sleep(forTimeInterval: 0.2)
                try? Data(#"{"paused":true,"capture":{"token":7}}"#.utf8).write(to: control, options: .atomic)
            }
            written.signal()
        }
        locked.wait()
        StatusChannel.clearControl(control)
        written.wait()
        #expect(!FileManager.default.fileExists(atPath: control.path))
    }
}
