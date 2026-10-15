import Foundation
import HIDPP
import PureMouseKit

// The daemon's view of the shared config model (PureMouseKit): device mappings and logging.

extension Config {
    /// Loads `url`, logging problems that do not fail the load.
    static func loadLogged(from url: URL) throws -> Config {
        let config = try load(from: url)
        for name in config.unknownButtons {
            Log.error("config: unknown button '\(name)'")
        }
        return config
    }
}

extension Config.WheelMode {
    var smartShift: SmartShift.Mode { self == .ratchet ? .ratchet : .freespin }
}

extension Config.Binding.Gesture {
    func action(for direction: GestureRecognizer.Direction) -> Action {
        switch direction {
        case .up: up
        case .down: down
        case .left: left
        case .right: right
        }
    }
}
