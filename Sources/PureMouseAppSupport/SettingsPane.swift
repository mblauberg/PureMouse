import Foundation

/// A Settings toolbar tab. The window remembers the last one shown.
public enum SettingsTab: String, CaseIterable, Sendable {
    case general, mouse, apps, about

    /// The tabs the toolbar shows, in order. A new tab (a keyboard, say) is one more entry here;
    /// the window builds its toolbar from this list.
    public static let shown: [SettingsTab] = allCases
}

/// A segment of the Mouse tab. The tab remembers the last one shown.
public enum MouseSegment: String, CaseIterable, Sendable {
    case buttons, scrolling, pointer
}

/// A place in Settings someone asks for: the menu, the daemon's `show-settings` request or
/// `PUREMOUSE_DEV_PANE`. Its raw value is the word written in `show-settings`: a tab
/// ("general", "mouse", "apps", "about"), or a Mouse segment ("buttons", "scrolling", "pointer"),
/// which opens Mouse on that segment.
public enum SettingsPane: Hashable, Sendable {
    /// A tab; Mouse opens on the segment last shown.
    case tab(SettingsTab)
    /// Mouse, on this segment.
    case mouse(MouseSegment)

    public init?(rawValue: String) {
        if let segment = MouseSegment(rawValue: rawValue) {
            self = .mouse(segment)
        } else if let tab = SettingsTab(rawValue: rawValue), SettingsTab.shown.contains(tab) {
            self = .tab(tab)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .tab(let tab): tab.rawValue
        case .mouse(let segment): segment.rawValue
        }
    }
}

/// A sheet a request asks Settings to open over its pane. Its raw value is the word written after
/// the pane in `show-settings` ("pointer.presets").
public enum SettingsSheet: String, Sendable {
    /// Pointer's presets list.
    case presets

    /// The pane the sheet opens over.
    public var pane: SettingsPane {
        switch self {
        case .presets: .mouse(.pointer)
        }
    }
}

/// What Settings shows: a tab, and the segment the Mouse tab is on (kept while another tab shows).
public struct SettingsSelection: Equatable, Sendable {
    public var tab: SettingsTab
    public var segment: MouseSegment

    public init(tab: SettingsTab, segment: MouseSegment) {
        self.tab = tab
        self.segment = segment
    }

    /// What Settings opens on, from the tab and segment stored when it was last shown. A first run,
    /// or a tab no longer shown or not understood, opens Mouse; an unknown segment opens Buttons.
    public static func remembered(tab: String?, segment: String?) -> SettingsSelection {
        let tab = tab.flatMap(SettingsTab.init).flatMap { SettingsTab.shown.contains($0) ? $0 : nil }
        return SettingsSelection(tab: tab ?? .mouse, segment: segment.flatMap(MouseSegment.init) ?? .buttons)
    }

    /// The selection after a request: its tab, and for a segment, Mouse on that segment.
    public func opening(_ pane: SettingsPane) -> SettingsSelection {
        switch pane {
        case .tab(let tab): SettingsSelection(tab: tab, segment: segment)
        case .mouse(let segment): SettingsSelection(tab: .mouse, segment: segment)
        }
    }
}

/// The System Settings privacy pane an attention row or a permission row opens.
public enum PrivacyPane: String, Sendable {
    case accessibility = "Privacy_Accessibility"
    case inputMonitoring = "Privacy_ListenEvent"

    public var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
}

/// Pages both apps open. Settings' own are `PureMouseSettingsUI`'s extension.
public enum Links {
    public static let releases = URL(string: "https://github.com/mblauberg/PureMouse/releases")!
}
