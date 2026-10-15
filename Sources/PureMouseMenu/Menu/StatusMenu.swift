import AppKit
import PureMouseKit

/// The status item and its plain `NSMenu`, rebuilt each time it opens (`menuNeedsUpdate`), so it
/// costs nothing while closed.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let app: AppController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(model: AppModel, app: AppController) {
        self.model = model
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    #if DEBUG
    func open(appearance: NSAppearance?) {
        menu.appearance = appearance
        statusItem.button?.performClick(nil)
    }
    #endif

    private(set) var isOpen = false

    func menuWillOpen(_ menu: NSMenu) { isOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        // An action chosen in the menu runs after this; let it start first.
        DispatchQueue.main.async { [app] in app.relaunchIfIdle() }
    }

    private var shown: (dimmed: Bool, badge: StatusIcon.Badge, label: String)?

    /// Redraws the glyph and relabels it only when what they show has changed.
    func updateIcon() {
        guard let button = statusItem.button else { return }
        let badge: StatusIcon.Badge = model.needsAttention ? .attention : model.lowBattery ? .battery : .none
        let dimmed = !model.daemonRunning || model.paused
        let label = StatusText.accessibilityLabel(model: model)
        if shown?.dimmed != dimmed || shown?.badge != badge {
            button.image = StatusIcon.image(dimmed: dimmed, badge: badge)
        }
        if shown?.label != label {
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
        shown = (dimmed, badge, label)
    }

    // MARK: Building

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshLiveness()
        model.reloadConfig()
        menu.removeAllItems()
        let option = NSEvent.modifierFlags.contains(.option)
        let running = model.daemonRunning

        if !running {
            addHeader(title: "PureMouse Is Off", subtitle: "The mouse works as it does without PureMouse")
            if model.statusTooNew { addAttention("Update the Menu Bar App…") { [app] in app.openReleases() } }
        } else {
            if model.devices.isEmpty {
                // While paused the daemon drops its sessions, so it reports no devices.
                if model.paused {
                    addHeader(title: "PureMouse Is Paused", subtitle: "The mouse works as it does without PureMouse")
                } else {
                    addHeader(title: "No Mouse Connected", subtitle: "Turn on your mouse or check the receiver")
                }
            }
            for device in model.devices {
                let subtitle = (model.paused ? "Paused · " : "") + StatusText.subtitle(device)
                addHeader(title: device.name, subtitle: subtitle,
                          detail: StatusText.detail(device, version: model.status?.version ?? "dev"))
            }
            addAttentionRows()
        }

        menu.addItem(.separator())
        let smooth = item("Smooth Scrolling") { [model] in
            model.update { $0.smoothScrollEnabled.toggle() }
        }
        smooth.state = model.config.smoothScrollEnabled ? .on : .off
        smooth.isEnabled = running && !model.readOnly
        menu.addItem(smooth)
        let pointer = NSMenuItem(title: "Pointer Speed", action: nil, keyEquivalent: "")
        pointer.submenu = pointerMenu()
        pointer.isEnabled = running
        menu.addItem(pointer)

        // Start, Pause and Resume share one slot, so nothing below them moves between states.
        menu.addItem(.separator())
        if !running {
            menu.addItem(item("Start PureMouse") { Lifecycle.perform(.register) })
        } else {
            let paused = model.paused
            menu.addItem(item(paused ? "Resume PureMouse" : "Pause PureMouse") { [model] in model.setPaused(!paused) })
            if option {
                menu.addItem(item("Reload Config") { [model] in model.reloadDaemonConfig() })
                menu.addItem(item("Show Log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.log])
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", key: ",") { [app] in app.showSettings() })
        menu.addItem(item("Quit PureMouse", key: "q") { [app] in app.quitAll() })
        let hide = item("Hide Menu Bar Icon", key: "q") { [app] in app.hideMenuBarIcon() }
        hide.keyEquivalentModifierMask = [.command, .option]
        hide.isAlternate = true
        menu.addItem(hide)
    }

    private func addAttentionRows() {
        if model.statusTooNew {
            addAttention("Update the Menu Bar App…") { [app] in app.openReleases() }
        }
        if model.accessibilityMissing {
            addAttention("Allow Accessibility Access…") { [app] in app.openPrivacy(.accessibility) }
        }
        if model.inputMonitoringMissing, model.hasBluetoothDevice {
            addAttention("Allow Input Monitoring…") { [app] in app.openPrivacy(.inputMonitoring) }
        }
        if model.configError != nil {
            addAttention("Fix Config Error…") { [app] in app.showSettings(pane: .general) }
        }
        if model.logiOptionsRunning {
            addAttention("Quit Logi Options+…") { [app] in app.showSettings(pane: .general) }
        }
    }

    /// The device header: glyph, bold name and a secondary line. Holding ⌥ swaps in an alternate
    /// with the detail line (DPI, wheel mode, version).
    private func addHeader(title: String, subtitle: String, detail: String? = nil) {
        let normal = headerItem(title: title, lines: [subtitle])
        menu.addItem(normal)
        if let detail {
            let alternate = headerItem(title: title, lines: [subtitle, detail])
            alternate.keyEquivalentModifierMask = .option
            alternate.isAlternate = true
            menu.addItem(alternate)
        }
    }

    private func headerItem(title: String, lines: [String]) -> NSMenuItem {
        let header = NSMenuItem(title: title, action: #selector(openSettingsFromHeader), keyEquivalent: "")
        header.target = self
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0).bold,
        ])
        for line in lines {
            text.append(NSAttributedString(string: "\n" + line, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        header.attributedTitle = text
        header.image = StatusIcon.headerImage()
        header.setAccessibilityLabel(([title] + lines).joined(separator: ", "))
        return header
    }

    @objc private func openSettingsFromHeader() { app.showSettings() }

    private func addAttention(_ title: String, _ action: @escaping @MainActor () -> Void) {
        let row = item(title, action: action)
        // Shown in the checkmark column, like the mockup's "!".
        row.state = .on
        row.onStateImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Needs attention")
        menu.addItem(row)
    }

    private func pointerMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let presets = model.config.dpiPresets
        // The mouse's own value first: a Cycle Pointer Speed press changes it, not the config.
        let current = model.liveDevice?.dpi ?? model.config.int(["dpi"])
        // A preset off the sensor's list runs at its nearest step, as the daemon snaps it.
        let steps = model.liveDevice?.dpiSteps ?? []
        let selected = presets.first { DPIPresets.snap($0, to: steps) == current }
        for preset in presets {
            let row = item(Format.dpi(preset)) { [model] in model.setDPI(preset) }
            row.state = preset == selected ? .on : .off
            row.isEnabled = !model.readOnly
            submenu.addItem(row)
        }
        if let current, selected == nil {
            let row = NSMenuItem(title: presets.isEmpty ? Format.dpi(current) : "Custom: \(Format.dpi(current))",
                                 action: nil, keyEquivalent: "")
            row.state = .on
            row.isEnabled = false
            submenu.addItem(row)
        }
        if submenu.numberOfItems > 0 { submenu.addItem(.separator()) }
        submenu.addItem(item(presets.isEmpty ? "Add Presets…" : "Edit Presets…") { [app] in app.showSettings(pane: .pointer) })
        return submenu
    }

    private func item(_ title: String, key: String = "", action: @escaping @MainActor () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, key: key, action: action)
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, key: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
