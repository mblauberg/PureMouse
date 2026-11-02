import Foundation
import PureMouseAppSupport

extension SettingsPane {
    var title: String {
        switch self {
        case .general: "General"
        case .buttons: "Buttons"
        case .scrolling: "Scrolling"
        case .pointer: "Pointer"
        case .apps: "Apps"
        case .about: "About"
        }
    }

    /// SF Symbols available on macOS 14.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .buttons: "computermouse"
        case .scrolling: "arrow.up.and.down"
        case .pointer: "cursorarrow"
        case .apps: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

/// The pages only Settings opens.
extension Links {
    static let repository = URL(string: "https://github.com/mblauberg/PureMouse")!
    static let licence = URL(string: "https://github.com/mblauberg/PureMouse/blob/main/LICENSE")!
    static let sponsors = URL(string: "https://github.com/sponsors/mblauberg")!
    static let logiOptions = URL(string: "https://github.com/mblauberg/PureMouse/blob/main/docs/troubleshooting.md#logi-options")!
}
