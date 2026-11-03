import AppKit
import Foundation
import Testing
@testable import PureMouseSettingsUI

// The shortcut sheet leads with the recorder. Typing the shortcut is behind "Enter as Text…", or
// shows once a recording ends on modifiers alone (docs/ui-design.md, Forms and controls).

@MainActor @Suite struct ShortcutSheetTests {
    private static let ui = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI")

    @Test func enteringAsTextIsAnEllipsisButton() {
        #expect(ShortcutSheet.enterAsText == "Enter as Text…")
    }

    /// Modifiers released with no key after some were held: the recording ended on modifiers alone.
    @Test func aRecordingEndsOnModifiersOnlyWhenTheyAreAllReleased() {
        #expect(ShortcutRecorder.endsWithoutKey(held: [.command], now: []))
        #expect(ShortcutRecorder.endsWithoutKey(held: [.control, .shift], now: []))
        #expect(!ShortcutRecorder.endsWithoutKey(held: [], now: [.command]), "pressing a modifier is not an end")
        #expect(!ShortcutRecorder.endsWithoutKey(held: [.command], now: [.command, .shift]), "holding another is not an end")
        #expect(!ShortcutRecorder.endsWithoutKey(held: [], now: []))
    }

    /// A reserved shortcut that moves focus deactivates the app while its modifier is down, so the
    /// release never arrives: losing focus then ends the recording as a modifier-only one.
    @Test(arguments: [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification])
    func losingFocusWithModifiersDownEndsTheRecording(notification: Notification.Name) {
        let recorder = ShortcutRecorder()
        recorder.start()
        recorder.modifiersChanged(to: [.command])
        #expect(recorder.recording)
        NotificationCenter.default.post(name: notification, object: nil)
        #expect(!recorder.recording)
        #expect(recorder.endedOnModifiers, "the sheet reveals the text field")
        #expect(recorder.held.isEmpty)
    }

    @Test func losingFocusWithNoModifierDownLeavesTheRecordingOn() {
        let recorder = ShortcutRecorder()
        recorder.start()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(recorder.recording)
        #expect(!recorder.endedOnModifiers)
        recorder.stop()
    }

    @Test func aStoppedRecorderIgnoresLosingFocus() {
        let recorder = ShortcutRecorder()
        recorder.start()
        recorder.modifiersChanged(to: [.command])
        recorder.stop()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!recorder.endedOnModifiers, "the observers went with the recording")
    }

    @Test func releasingModifiersWithNoKeyStillEndsTheRecording() {
        let recorder = ShortcutRecorder()
        recorder.start()
        recorder.modifiersChanged(to: [.control])
        recorder.modifiersChanged(to: [])
        #expect(!recorder.recording)
        #expect(recorder.endedOnModifiers)
    }

    /// The recorder comes before the text field in the sheet, and the field sits inside the branch
    /// that "Enter as Text…" or a modifier-only end shows; the else branch offers the button.
    @Test func theTextFieldIsBehindTheButton() throws {
        let sheets = try String(contentsOf: Self.ui.appending(path: "Sheets.swift"), encoding: .utf8)
        let recorder = try #require(sheets.range(of: "RecorderField(recorder: recorder)"))
        let branch = try #require(sheets.range(of: "if showsTyping {"))
        let field = try #require(sheets.range(of: "TextField(Self.typingPrompt"))
        let otherwise = try #require(sheets.range(of: "} else {", range: branch.upperBound..<sheets.endIndex))
        let button = try #require(sheets.range(of: "Button(Self.enterAsText)"))
        #expect(recorder.upperBound <= branch.lowerBound)
        #expect(branch.upperBound <= field.lowerBound && field.upperBound <= otherwise.lowerBound)
        #expect(otherwise.upperBound <= button.lowerBound)
        #expect(sheets.contains("var showsTyping: Bool { typingRequested || recorder.endedOnModifiers }"))
    }
}
