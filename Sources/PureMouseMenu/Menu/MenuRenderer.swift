import AppKit

/// Turns `MenuPlan` rows into `NSMenuItem`s; `perform` runs a row's action when it is chosen.
@MainActor
struct MenuRenderer {
    let perform: @MainActor (MenuAction) -> Void

    func fill(_ menu: NSMenu, with rows: [MenuRow]) {
        menu.removeAllItems()
        for row in rows { menu.addItem(item(for: row)) }
    }

    private func item(for row: MenuRow) -> NSMenuItem {
        switch row {
        case .separator:
            return .separator()
        case let .header(title, lines, alternate):
            let header = headerItem(title: title, lines: lines)
            if alternate {
                header.keyEquivalentModifierMask = .option
                header.isAlternate = true
            }
            return header
        case let .item(plan):
            return item(for: plan)
        }
    }

    private func item(for plan: MenuItem) -> NSMenuItem {
        let item: NSMenuItem
        if let action = plan.action {
            item = ClosureMenuItem(title: plan.title, key: plan.key) { [perform] in perform(action) }
        } else {
            item = NSMenuItem(title: plan.title, action: nil, keyEquivalent: plan.key)
        }
        if plan.alternate {
            item.keyEquivalentModifierMask = .option
            item.isAlternate = true
        }
        if plan.checked { item.state = .on }
        if plan.attention {
            // Shown in the checkmark column, like the mockup's "!".
            item.state = .on
            item.onStateImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                        accessibilityDescription: "Needs attention")
        }
        item.isEnabled = plan.enabled
        if let rows = plan.submenu {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            fill(submenu, with: rows)
            item.submenu = submenu
        }
        return item
    }

    /// The device header: glyph, bold name and secondary lines; choosing it opens Settings.
    private func headerItem(title: String, lines: [String]) -> NSMenuItem {
        let header = ClosureMenuItem(title: title, key: "") { [perform] in perform(.openSettings(nil)) }
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
        header.setAccessibilityLabel(MenuPlan.spokenHeader(title: title, lines: lines))
        return header
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
