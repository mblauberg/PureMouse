import Foundation
import Testing
@testable import PureMouseKit

// `show-settings`, in a temporary directory.

private func requestFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "PureMouseKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "show-settings")
}

/// The daemon's `openMenu` writes `SettingsRequest.write("")`: while a reader holds the lock (it
/// has read the request and not yet removed it), that write waits, so it is neither cut short nor
/// removed unread.
@Test func theDaemonsRequestWaitsForAReaderHoldingTheLock() throws {
    let file = requestFile()
    SettingsRequest.write("pointer", to: file)
    let held = DispatchSemaphore(value: 0)
    let reader = Thread {
        try? FileLock.withLock(FileLock.url(for: file)) {
            held.signal()
            Thread.sleep(forTimeInterval: 0.4)
            try? FileManager.default.removeItem(at: file) // the reader's remove, after its read
        }
    }
    reader.start()
    held.wait()
    let start = Date()
    SettingsRequest.write("", to: file)
    #expect(Date().timeIntervalSince(start) >= 0.3, "the write waited for the lock")
    let taken = try #require(SettingsRequest.take(from: file), "the daemon's request survived the reader's remove")
    #expect(taken.body == "")
}

@Test func aRequestIsTakenOnceWithItsBody() {
    let file = requestFile()
    SettingsRequest.write("apps", to: file)
    #expect(SettingsRequest.take(from: file)?.body == "apps")
    #expect(SettingsRequest.take(from: file) == nil)
}
