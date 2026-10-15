import AppKit
import PureMouseKit
import SwiftUI

/// What a sheet edits: a button, or one direction of a gesture button.
struct BindingTarget: Hashable {
    let button: String
    var direction: String?

    var title: String {
        let name = NamedButton(rawValue: button)?.label ?? "Control \(button)"
        guard let direction else { return name }
        return "\(name), \(Gesture.label(direction).lowercased())"
    }
}

struct SheetRequest: Identifiable {
    enum Kind { case shortcut, command }
    let kind: Kind
    let target: BindingTarget
    let initial: String
    var id: String { "\(kind)\(target.button)\(target.direction ?? "")" }
}

/// Records a keyboard shortcut: press it, or type it as the config spells it.
struct ShortcutSheet: View {
    let request: SheetRequest
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = ShortcutRecorder()
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var typedValid: Bool { ShortcutCheck.isValid(typed) }

    /// The spec Save writes: the typed one while that field has text, else the recorded one.
    private var result: String? {
        if !typed.isEmpty { return typedValid ? typed.lowercased() : nil }
        return recorder.spec
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard Shortcut").font(.headline)
                Text("What \(request.target.title) presses.").foregroundStyle(.secondary)
            }
            RecorderField(recorder: recorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("Some shortcuts never reach PureMouse (macOS keeps ⌃← and similar). Type those instead:")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Type it instead, e.g. ctrl+left", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($typing)
                    .onChange(of: typing) { _, focused in if focused { recorder.stop() } }
                    .accessibilityLabel("Type the shortcut instead")
                if !typed.isEmpty {
                    if typedValid, let display = Shortcut.display(typed) {
                        Label(display, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                            .labelStyle(StatusLabelStyle())
                    } else {
                        Text("Use names like cmd, shift, opt, ctrl with a key: a, 4, left, f11, space, return.")
                            .font(.callout).foregroundStyle(.red)
                    }
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
        }
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
    @ObservationIgnored private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        recording = true
        held = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated { result = self?.handle(event) ?? event }
            return result
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        held = []
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = Self.modifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            held = modifiers
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

/// The recorder's field: shows the shortcut in ⌃⌥⇧⌘ glyphs; click it to record again.
private struct RecorderField: View {
    let recorder: ShortcutRecorder

    private var text: String {
        if recorder.recording {
            let held = Shortcut.display(heldSpec) ?? ""
            return held.isEmpty ? "Type a shortcut" : held
        }
        return recorder.spec.flatMap(Shortcut.display) ?? "Click to record"
    }

    /// The held modifiers with a placeholder key, for display only.
    private var heldSpec: String {
        let names = [(Shortcut.Modifiers.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")]
            .filter { recorder.held.contains($0.0) }.map(\.1)
        return names.isEmpty ? "" : (names + ["…"]).joined(separator: "+")
    }

    var body: some View {
        Button {
            recorder.recording ? recorder.stop() : recorder.start()
        } label: {
            HStack {
                Text(recorder.recording && recorder.held.isEmpty ? "Type a shortcut" : displayText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(recorder.recording && recorder.held.isEmpty ? .secondary : .primary)
                Spacer()
                if recorder.recording {
                    Text("Recording").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(recorder.recording ? Color.accentColor : Color.secondary.opacity(0.35),
                                  lineWidth: recorder.recording ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shortcut")
        .accessibilityValue(recorder.spec.map(Shortcut.spoken) ?? "None")
        .accessibilityHint(recorder.recording ? "Press the shortcut now" : "Click to record a new shortcut")
    }

    private var displayText: String {
        if recorder.recording {
            let names = [(Shortcut.Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { recorder.held.contains($0.0) }.map(\.1)
            return names.joined()
        }
        return recorder.spec.flatMap(Shortcut.display) ?? "Click to record"
    }
}

/// Edits a shell command.
struct CommandSheet: View {
    let request: SheetRequest
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run Shell Command").font(.headline)
                Text("What \(request.target.title) runs.").foregroundStyle(.secondary)
            }
            TextField("open -a Safari", text: $command, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .lineLimit(3...8)
                .accessibilityLabel("Command")
            Text("Runs with /bin/sh as you. PureMouse does not show its output.")
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
        .frame(width: 440)
        .onAppear { command = request.initial }
    }
}
