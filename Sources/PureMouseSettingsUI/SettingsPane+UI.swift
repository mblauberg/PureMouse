import Foundation
import PureMouseAppSupport

extension SettingsTab {
    var title: String {
        switch self {
        case .general: "General"
        case .mouse: "Mouse"
        case .apps: "Apps"
        case .about: "About"
        }
    }

    /// SF Symbols available on macOS 14.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .mouse: "computermouse"
        case .apps: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

extension MouseSegment {
    var title: String {
        switch self {
        case .buttons: "Buttons"
        case .scrolling: "Scrolling"
        case .pointer: "Pointer"
        }
    }
}

/// The pages only Settings opens.
extension Links {
    static let repository = URL(string: "https://github.com/mblauberg/PureMouse")!
    static let licence = URL(string: "https://github.com/mblauberg/PureMouse/blob/main/LICENSE")!
    static let sponsors = URL(string: "https://github.com/sponsors/mblauberg")!
}
