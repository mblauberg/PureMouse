import Foundation
import HIDPP
import PureMouseKit

// The daemon's view of the shared config model (PureMouseKit): device mappings and logging.

extension Config {
    /// Decodes a config file, logging problems that do not fail the load.
    static func loadLogged(from data: Data) throws -> Config {
        let config = try JSONDecoder().decode(Config.self, from: data)
        for name in config.unknownButtons {
            Log.error("config: unknown button '\(name)'")
        }
        return config
    }
}

extension Config {
    /// The preset after `current`, wrapping: the smallest preset above it, else the smallest.
    /// `presets` should already be snapped to resolutions the sensor accepts.
    static func nextPreset(_ presets: [Int], after current: Int) -> Int? {
        let sorted = Set(presets).sorted()
        return sorted.first { $0 > current } ?? sorted.first
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
