import Foundation

/// Validates config JSON exactly as the daemon will load it, so the menu bar app never writes a
/// file the daemon would reject.
public enum ConfigCheck {
    /// Throws the decoder's error, which names the offending field.
    public static func validate(_ data: Data) throws {
        _ = try JSONDecoder().decode(Config.self, from: data)
    }
}
