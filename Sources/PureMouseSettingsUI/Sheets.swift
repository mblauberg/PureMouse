import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// What a sheet edits: a button, or one direction of a gesture button.
struct BindingTarget: Hashable {
    let button: String
    var direction: String?
    /// The app whose binding this is (`apps.<key>`), or nil for the global one.
    var app: String?
    /// What the sheet calls the control, where it is not a button ("turning the thumb wheel left").
    var label: String?
    /// The app's display name, for an app's binding ("Safari").
    var appName: String?

    var title: String {
        if let label { return label }
        let name = NamedButton.title(forKey: button)
        guard let direction else { return name }
        return "\(name), \(Gesture.label(direction).lowercased())"
    }

    /// The control in a sentence: "the top button", "the gesture button", "control 0x00c3".
    var spokenName: String {
        if let label { return label }
        return switch NamedButton(rawValue: button) {
        case .gesture: "the gesture button"
        case .back: "the back button"
        case .forward: "the forward button"
        case .top: "the top button"
        case .middle: "the wheel button"
        case .thumbPanel: "the thumb panel"
        case nil: "control \(button)"
        }
    }

    /// A sheet's subtitle, naming the control and the app: "For the top button in Safari.",
    /// "For the gesture button, move up."
    var subtitle: String {
        var text = "For \(spokenName)"
        if let appName { text += " in \(appName)" }
        if let direction, label == nil { text += ", \(Gesture.label(direction).lowercased())" }
        return text + "."
    }
}

struct SheetRequest: Identifiable {
    enum Kind { case shortcut, command }
    let kind: Kind
    let target: BindingTarget
    let initial: String
    var id: String { "\(kind)\(target.app ?? "")\(target.button)\(target.direction ?? "")" }
}

/// Records a keyboard shortcut. The recorder leads; typing it as the config spells it is behind
/// "Enter as Text…", or shows once a recording ends on modifiers alone (`ShortcutRecorder`).
struct ShortcutSheet: View {
    static let title = "Keyboard Shortcut"
    static let enterAsText = "Enter as Text…"
    static let typingPrompt = "Or enter it, such as ctrl+left"
    static let caption = "macOS keeps some shortcuts, such as ⌃←. Enter those instead."
    static let syntaxError = "Use cmd, shift, opt or ctrl with a key, such as a, 4, left, f11, space or return."

    let request: SheetRequest
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = ShortcutRecorder()
    @State private var typed = ""
    @FocusState private var typing: Bool
    /// "Enter as Text…" was pressed.
    @State private var typingRequested = false

    /// The text field and its caption show once asked for, or when a recording ended on modifiers.
    private var showsTyping: Bool { typingRequested || recorder.endedOnModifiers }

    private var typedValid: Bool { ShortcutCheck.isValid(typed) }

    /// Shows the text field and moves focus to it on the next turn, once the field is in the view.
    private func revealTyping() {
        typingRequested = true
        DispatchQueue.main.async { typing = true }
    }

    /// The spec Save writes: the typed one while that field has text, else the recorded one.
    private var result: String? {
        if !typed.isEmpty { return typedValid ? typed.lowercased() : nil }
        return recorder.spec
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title).font(.headline)
                Text(request.target.subtitle).foregroundStyle(.secondary)
            }
            RecorderField(recorder: recorder)
            if showsTyping {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(Self.typingPrompt, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .focused($typing)
                        .onChange(of: typing) { _, focused in if focused { recorder.stop() } }
                        .accessibilityLabel("Enter the shortcut")
                    Text(Self.caption)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        // The sheet's width, not the text's ideal width, so it wraps at the edge.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !typed.isEmpty {
                        if typedValid, let display = Shortcut.display(typed) {
                            Label(display, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                                .labelStyle(StatusLabelStyle())
                        } else {
                            Label {
                                Text(Self.syntaxError)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                            }
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                HStack {
                    Button(Self.enterAsText) { revealTyping() }
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let result { save(result) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result == nil || recorder.recording)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if Shortcut.isValid(request.initial) { recorder.spec = request.initial }
            recorder.start()
            // A sheet may give its first text field focus as it opens, which stopped the recording
            // and showed a focus ring. Recording comes first; a click on the field still switches
            // to typing.
            DispatchQueue.main.async {
                typing = false
                recorder.start()
            }
            #if DEBUG
            if DevHooks.shortcutTextRequested { typingRequested = true }
            #endif
        }
        // A recording that ended on modifiers alone moves on to typing, as "Enter as Text…" does.
        .onChange(of: recorder.endedOnModifiers) { _, ended in if ended { revealTyping() } }
        .onDisappear { recorder.stop() }
    }
}

/// Holds a local key monitor only while recording.
@MainActor @Observable
final class ShortcutRecorder {
    var spec: String?
    private(set) var recording = false
    /// Modifiers held so far, shown while recording.
    private(set) var held: Shortcut.Modifiers = []
    /// Set when a recording ended on modifiers alone (`endsWithoutKey`). macOS keeps some shortcuts,
    /// and their key often never reaches the app, so the sheet then offers to enter the text.
    private(set) var endedOnModifiers = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObservers: [any NSObjectProtocol] = []

    /// Whether a change from `held` to `now` ends a recording with no key: some modifiers were held
    /// and now none are.
    static func endsWithoutKey(held: Shortcut.Modifiers, now: Shortcut.Modifiers) -> Bool {
        !held.isEmpty && now.isEmpty
    }

    func start() {
        guard monitor == nil else { return }
        recording = true
        held = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            // handle returns nil for an event it consumed; only a released recorder passes it on.
            MainActor.assumeIsolated {
                if let self { result = self.handle(event) }
            }
            return result
        }
        // A reserved shortcut that moves focus (⌘Space, ⌃←, Mission Control) deactivates the app
        // while its modifier is down, so the release never arrives here.
        let center = NotificationCenter.default
        resignObservers = [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.resigned() }
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resignObservers.forEach { NotificationCenter.default.removeObserver($0) }
        resignObservers = []
        recording = false
        held = []
    }

    /// The app or the window lost focus. With modifiers down the release will not arrive, so this
    /// ends the recording as if they had been released: the sheet then offers the text field. With
    /// none down, recording goes on.
    func resigned() {
        guard recording, !held.isEmpty else { return }
        endedOnModifiers = true
        stop()
    }

    /// The modifiers now held; a release of all of them with no key ends the recording.
    func modifiersChanged(to modifiers: Shortcut.Modifiers) {
        if Self.endsWithoutKey(held: held, now: modifiers) {
            endedOnModifiers = true
            stop()
        } else {
            held = modifiers
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = Self.modifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            modifiersChanged(to: modifiers)
            return nil
        }
        // Plain Escape stops recording (and leaves the sheet's Cancel to a second press).
        if event.keyCode == 53, modifiers.isEmpty {
            stop()
            return nil
        }
        guard let recorded = Shortcut.spec(keyCode: event.keyCode, modifiers: modifiers) else {
            NSSound.beep()
            return nil
        }
        spec = recorded
        stop()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Recorded \(Shortcut.spoken(recorded))",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        return nil
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Shortcut.Modifiers {
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

/// The recorder's field: shows the shortcut in ⌃⌥⇧⌘ glyphs; press it to record again.
///
/// A `.bordered` button, since no system control records a shortcut: a text field takes typed
/// characters, not a ⌘ or ⌃ chord, and SwiftUI's `KeyboardShortcut` only declares one. The sheet
/// listens through a local key monitor (`ShortcutRecorder`) while this reads "Recording…".
struct RecorderField: View {
    let recorder: ShortcutRecorder

    static let idle = "Record Shortcut"
    static let recording = "Recording…"

    var body: some View {
        Button {
            recorder.recording ? recorder.stop() : recorder.start()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: recorder.recording ? "record.circle" : "keyboard")
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text(displayText)
                    .font(.title3)
                    .foregroundStyle(recorder.spec == nil || recorder.recording && recorder.held.isEmpty ? .secondary : .primary)
                // Once modifiers are held they replace the word, so say it beside them.
                if recorder.recording && !recorder.held.isEmpty {
                    Text(Self.recording).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        // While recording, the field listens through its own monitor and draws its own state;
        // the sheet focuses it on open, which would otherwise ring it before any key is pressed.
        .focusEffectDisabled(recorder.recording)
        .accessibilityLabel("Shortcut")
        .accessibilityValue(recorder.spec.map(Shortcut.spoken) ?? "None")
        .accessibilityHint(recorder.recording ? "Press the shortcut now" : "Records a new shortcut")
    }

    /// "Recording…" until a modifier is held, then the held modifiers; idle, the shortcut, else
    /// "Record Shortcut".
    private var displayText: String {
        if recorder.recording {
            let names = [(Shortcut.Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { recorder.held.contains($0.0) }.map(\.1)
            return names.isEmpty ? Self.recording : names.joined()
        }
        return recorder.spec.flatMap(Shortcut.display) ?? Self.idle
    }
}

/// Edits a shell command.
struct CommandSheet: View {
    static let title = "Run Command"
    static let caption = "Runs as your user account. Output isn't shown."

    let request: SheetRequest
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title).font(.headline)
                Text(request.target.subtitle).foregroundStyle(.secondary)
            }
            TextField("open -a Safari", text: $command, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .lineLimit(3...8)
                .accessibilityLabel("Command")
            Text(Self.caption)
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(command.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { command = request.initial }
    }
}
