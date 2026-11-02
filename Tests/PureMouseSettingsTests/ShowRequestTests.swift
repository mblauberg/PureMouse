import Foundation
import os
import Testing
@testable import PureMouseAppSupport

// How the helper learns which pane to open: the `show-settings` file and the pane last shown.
// `ShowRequest.post` also rings the real doorbell, so these write the file only.

private func requestFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "PureMouseSettingsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "show-settings")
}

@Test func aRequestNamesThePaneToOpenAndIsConsumedOnce() throws {
    let file = requestFile()
    ShowRequest.write(pane: .pointer, to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: .pointer))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(ShowRequest.consume(from: file, now: Date()) == nil)
}

@Test func anEmptyOrUnknownPaneOpensTheLastOneShown() throws {
    let file = requestFile()
    ShowRequest.write(pane: nil, to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: nil))
    // The daemon's request (opening PureMouse.app from the Finder) is an empty file.
    try Data("sideways\n".utf8).write(to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: nil))
}

@Test func aPaneWrittenByHandWithANewlineStillCounts() throws {
    let file = requestFile()
    ShowRequest.write(pane: nil, to: file)
    try Data("pointer\n".utf8).write(to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: .pointer))
}

@Test func aRequestOlderThanFiveSecondsIsDroppedAndRemoved() throws {
    let file = requestFile()
    ShowRequest.write(pane: .apps, to: file)
    let written = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    #expect(ShowRequest.consume(from: file, now: written.addingTimeInterval(5)) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    ShowRequest.write(pane: .apps, to: file)
    let again = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    #expect(ShowRequest.consume(from: file, now: again.addingTimeInterval(4.9)) == ShowRequest(pane: .apps))
}

@Test func aRequestIsNeverReadHalfWrittenWhileAnotherIsWritten() {
    let file = requestFile()
    let rounds = 4000
    let bad = OSAllocatedUnfairLock(initialState: 0)
    // Half the threads keep asking for the pointer pane, half keep taking requests; a reader
    // that sees the file between its truncation and its write would read no pane.
    DispatchQueue.concurrentPerform(iterations: rounds) { round in
        if round.isMultiple(of: 2) {
            ShowRequest.write(pane: .pointer, to: file)
        } else if let request = ShowRequest.consume(from: file, now: Date()), request.pane != .pointer {
            bad.withLock { $0 += 1 }
        }
    }
    #expect(bad.withLock { $0 } == 0)
}

@Test func settingsOpensOnTheRememberedPaneElseButtons() {
    #expect(SettingsPane.remembered("scrolling") == .scrolling)
    #expect(SettingsPane.remembered(nil) == .buttons)
    #expect(SettingsPane.remembered("Scrolling") == .buttons)
    #expect(SettingsPane.allCases.map(\.rawValue) == ["general", "buttons", "scrolling", "pointer", "apps", "about"])
}
