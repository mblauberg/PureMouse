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
    ShowRequest.write(ShowRequest(pane: .mouse(.pointer)), to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: .mouse(.pointer)))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(ShowRequest.consume(from: file, now: Date()) == nil)
}

@Test func anEmptyOrUnknownPaneOpensTheLastOneShown() throws {
    let file = requestFile()
    ShowRequest.write(ShowRequest(), to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: nil))
    // The daemon's request (opening PureMouse.app from the Finder) is an empty file.
    try Data("sideways\n".utf8).write(to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: nil))
}

@Test func aPaneWrittenByHandWithANewlineStillCounts() throws {
    let file = requestFile()
    ShowRequest.write(ShowRequest(), to: file)
    try Data("pointer\n".utf8).write(to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: .mouse(.pointer)))
}

@Test func aRequestCanNameASheetOverItsPane() throws {
    let file = requestFile()
    ShowRequest.write(ShowRequest(sheet: .presets), to: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == "pointer.presets")
    let request = ShowRequest.consume(from: file, now: Date())
    #expect(request == ShowRequest(pane: .mouse(.pointer), sheet: .presets))
    #expect(request?.sheet == .presets && request?.pane == .mouse(.pointer))
    // An unknown sheet leaves the pane; an unknown pane with a sheet still opens the sheet's.
    try Data("pointer.sideways".utf8).write(to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: .mouse(.pointer)))
    try Data("sideways.presets\n".utf8).write(to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(sheet: .presets))
}

@Test func aRequestCanNameAnAppWhoseSheetOpensInApps() throws {
    let file = requestFile()
    ShowRequest.write(ShowRequest(app: "com.apple.Safari"), to: file)
    // A bundle identifier holds dots, so the app follows a colon.
    #expect(try String(contentsOf: file, encoding: .utf8) == "apps:com.apple.Safari")
    let request = try #require(ShowRequest.consume(from: file, now: Date()))
    #expect(request.app == "com.apple.Safari" && request.pane == .tab(.apps) && request.sheet == nil)
    #expect(request == ShowRequest(app: "com.apple.Safari"))
    // Whatever pane is named, an app's sheet is in Apps; an empty app is no app.
    try Data("pointer:a.b\n".utf8).write(to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(app: "a.b"))
    try Data("apps:".utf8).write(to: file)
    #expect(ShowRequest.consume(from: file, now: Date()) == ShowRequest(pane: .tab(.apps)))
    #expect(ShowRequest(app: "  ").app == nil)
    // Every other request carries no app.
    #expect(ShowRequest(sheet: .presets).app == nil && ShowRequest(body: "pointer.presets").app == nil)
}

@Test func aRequestOlderThanFiveSecondsIsDroppedAndRemoved() throws {
    let file = requestFile()
    ShowRequest.write(ShowRequest(pane: .tab(.apps)), to: file)
    let written = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    #expect(ShowRequest.consume(from: file, now: written.addingTimeInterval(5)) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    ShowRequest.write(ShowRequest(pane: .tab(.apps)), to: file)
    let again = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    #expect(ShowRequest.consume(from: file, now: again.addingTimeInterval(4.9)) == ShowRequest(pane: .tab(.apps)))
}

@Test func aRequestIsNeverReadHalfWrittenWhileAnotherIsWritten() {
    let file = requestFile()
    let rounds = 4000
    let bad = OSAllocatedUnfairLock(initialState: 0)
    // Half the threads keep asking for the pointer pane, half keep taking requests; a reader
    // that sees the file between its truncation and its write would read no pane.
    DispatchQueue.concurrentPerform(iterations: rounds) { round in
        if round.isMultiple(of: 2) {
            ShowRequest.write(ShowRequest(pane: .mouse(.pointer)), to: file)
        } else if let request = ShowRequest.consume(from: file, now: Date()), request.pane != .mouse(.pointer) {
            bad.withLock { $0 += 1 }
        }
    }
    #expect(bad.withLock { $0 } == 0)
}
