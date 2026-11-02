#if DEBUG
import AppKit
import PureMouseAppSupport

/// Development only: `PUREMOUSE_DEV_AX_DUMP=1` prints each control's role, label, value and size,
/// as the accessibility tree reports them, then quits (status 1 if anything below is found).
///
/// - Without `PUREMOUSE_DEV_PANE` it visits every tab and Mouse segment in turn.
/// - With it, it dumps what the other hooks open: `PUREMOUSE_DEV_SHEET` (Advanced…, Presets),
///   `PUREMOUSE_DEV_APP` (the app sheet), `PUREMOUSE_DEV_PICKER` and `PUREMOUSE_DEV_SHORTCUT`.
///   Every window on screen is listed on its own (the window, then its sheet or popover).
///
/// It reports a control with no label, a button with no name (an image button), two controls with
/// the same label in one window, and a control smaller than 20 × 20 pt (docs/ui-design.md,
/// "Motion, sound and accessibility"). `PUREMOUSE_DEV_AX_DUMP_DELAY` is the seconds each view gets
/// to lay out (default 2).
@MainActor
enum DevAXDump {
    /// A control the person can operate, by its accessibility role.
    nonisolated private static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
        "AXTextField", "AXTextArea", "AXComboBox", "AXLink", "AXDisclosureTriangle", "AXIncrementor",
        "AXSegmentedControl", "AXSwitch",
    ]
    nonisolated static let minimumSide: CGFloat = 20

    struct Entry {
        let depth: Int
        let role: String
        let subrole: String
        let label: String
        let value: String
        let size: CGSize
        var isControl: Bool { DevAXDump.controlRoles.contains(role) }
    }

    static func schedule(_ environment: [String: String], show: @escaping (ShowRequest) -> Void) {
        guard environment["PUREMOUSE_DEV_AX_DUMP"] != nil else { return }
        // SwiftUI builds its accessibility tree only once an assistive client has asked for it, as
        // VoiceOver does by turning these on; this process is its own client.
        for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: name))
        }
        let delay = environment["PUREMOUSE_DEV_AX_DUMP_DELAY"].flatMap(Double.init) ?? 2
        // Opened by the other hooks, or every tab and segment in turn.
        let views: [SettingsPane?] = environment["PUREMOUSE_DEV_PANE"] != nil
            ? [nil] : [.tab(.general), .mouse(.buttons), .mouse(.scrolling), .mouse(.pointer), .tab(.apps), .tab(.about)]
        var failures = 0
        func visit(_ index: Int) {
            guard index < views.count else {
                fflush(stdout)
                // Not `terminate(_:)`, which quits with status 0 whatever was found. The dump has
                // edited nothing, so there is nothing to save.
                exit(failures > 0 ? 1 : 0)
            }
            if let pane = views[index] { show(ShowRequest(pane: pane)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                failures += dump(heading: views[index].map { "pane \($0.rawValue)" }
                                    ?? environment["PUREMOUSE_DEV_PANE"].map { "pane \($0)" } ?? "view")
                visit(index + 1)
            }
        }
        visit(0)
    }

    /// Prints every visible window of this process; returns how many problems it found.
    private static func dump(heading: String) -> Int {
        var problems = 0
        for window in NSApp.windows where window.isVisible && window.contentView != nil {
            let kind = window.sheetParent != nil ? "sheet"
                : String(describing: type(of: window)).contains("Popover") ? "popover" : "window"
            var entries: [Entry] = []
            walk(window, depth: 0, isRoot: true, into: &entries)
            print("== \(heading) / \(kind) \"\(window.title)\"")
            for entry in entries {
                let flag = entry.isControl && entry.label.isEmpty && entry.subrole.isEmpty ? "  <-- NO LABEL" : ""
                let text = [entry.subrole.isEmpty ? "" : " (\(entry.subrole))",
                            entry.label.isEmpty ? "" : " \"\(entry.label)\"",
                            entry.value.isEmpty ? "" : " = \(entry.value)"].joined()
                let size = entry.isControl ? "  \(Int(entry.size.width.rounded()))x\(Int(entry.size.height.rounded()))" : ""
                print(String(repeating: "  ", count: entry.depth) + entry.role + text + size + flag)
            }
            let found = check(entries)
            for line in found { print("PROBLEM \(heading) / \(kind): \(line)") }
            problems += found.count
            print("   \(entries.filter(\.isControl).count) controls, \(found.count) problems")
        }
        fflush(stdout)
        return problems
    }

    /// What is wrong with a window's controls.
    static func check(_ entries: [Entry]) -> [String] {
        var problems: [String] = []
        var seen: [String: Int] = [:]
        for entry in entries where entry.isControl {
            let name = "\(entry.role) \"\(entry.label)\""
            // The close, zoom and minimise buttons are the system's, labelled by AppKit for VoiceOver.
            // So are a scroll bar's arrows and pages.
            if entry.label.isEmpty, entry.subrole.hasSuffix("Button") || entry.subrole.hasSuffix("Arrow")
                || entry.subrole.hasSuffix("Page") { continue }
            if entry.label.isEmpty {
                problems.append(entry.role == "AXButton" ? "unnamed button \(entry.size)" : "empty label: \(name)")
                continue
            }
            seen[entry.label, default: 0] += 1
            // AppKit draws a slider 16 pt tall whatever the form does; its hit area is the whole track.
            // The mini switch is 36-38 x 16-18 and a slider 16 tall: AppKit sizes both, and the
            // allowed `.controlSize(.mini)` is the switch's. The row around each takes the click.
            if entry.role == "AXSlider" || entry.role == "AXCheckBox", entry.size.width >= minimumSide { continue }
            if entry.size.width < minimumSide || entry.size.height < minimumSide, entry.size != .zero {
                problems.append("smaller than \(Int(minimumSide)) x \(Int(minimumSide)) pt: \(name) \(entry.size)")
            }
        }
        for (label, count) in seen where count > 1 { problems.append("\(count) controls labelled \"\(label)\"") }
        return problems.sorted()
    }

    /// One accessibility element read through its Objective-C getters. SwiftUI's own nodes
    /// (`AccessibilityNode`) answer these selectors without declaring `NSAccessibilityProtocol`.
    private static func string(_ object: NSObject, _ key: String) -> String {
        guard object.responds(to: NSSelectorFromString(key)) else { return "" }
        let value = object.value(forKey: key)
        if let raw = value as? String { return raw }
        if let raw = value as? NSAttributedString { return raw.string }
        return value.map { "\($0)" } ?? ""
    }

    private static func walk(_ element: Any, depth: Int, isRoot: Bool = false, into entries: inout [Entry]) {
        guard let node = element as? NSObject else { return }
        let role = string(node, "accessibilityRole")
        // Not descended into: a window's sheet is dumped as a window of its own.
        if role == "AXSheet", !isRoot { return }
        var label = string(node, "accessibilityLabel")
        if label.isEmpty { label = string(node, "accessibilityTitle") }
        let value = string(node, "accessibilityValue")
        var size = CGSize.zero
        if node.responds(to: NSSelectorFromString("accessibilityFrame")),
           let frame = node.value(forKey: "accessibilityFrame") as? NSValue {
            size = frame.rectValue.size
        }
        let interesting = !role.isEmpty && role != "AXGroup" && role != "AXUnknown" && role != "AXSplitGroup"
        var childDepth = depth
        if interesting {
            entries.append(Entry(depth: depth, role: role, subrole: string(node, "accessibilitySubrole"),
                                 label: label, value: String(value.prefix(60)), size: size))
            childDepth += 1
        }
        if node.responds(to: NSSelectorFromString("accessibilityChildren")),
           let children = node.value(forKey: "accessibilityChildren") as? [Any] {
            for child in children { walk(child, depth: childDepth, into: &entries) }
        }
    }
}
#endif
