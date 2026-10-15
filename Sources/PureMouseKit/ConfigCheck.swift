import Foundation

/// Validates config JSON exactly as the daemon will load it, so the menu bar app never writes a
/// file the daemon would reject.
public enum ConfigCheck {
    /// Throws the decoder's error, which names the offending field; `message(for:)` words it.
    public static func validate(_ data: Data) throws {
        _ = try JSONDecoder().decode(Config.self, from: data)
    }

    /// One line for a failed load, naming the field: what the daemon logs and reports in
    /// `Status.ConfigState.error`.
    public static func message(for error: Error) -> String {
        func field(_ path: [CodingKey]) -> String {
            path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        func located(_ path: [CodingKey], _ text: String) -> String {
            let name = field(path)
            return name.isEmpty || text.hasPrefix(name) ? text : "\(name): \(text)"
        }
        switch error {
        case DecodingError.dataCorrupted(let context):
            var text = context.debugDescription
            if let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String {
                text += " \(detail)"
            }
            return located(context.codingPath, text)
        case DecodingError.typeMismatch(let type, let context):
            return located(context.codingPath, "expected \(kind(type))")
        case DecodingError.valueNotFound(let type, let context):
            return located(context.codingPath, "expected \(kind(type)), found null")
        case DecodingError.keyNotFound(let key, let context):
            return located(context.codingPath + [key], "missing")
        case CocoaError.fileReadNoSuchFile:
            return "no such file"
        default:
            return (error as NSError).localizedDescription
        }
    }

    /// A JSON value's kind in words, for someone editing the file rather than reading Swift.
    private static func kind(_ type: Any.Type) -> String {
        switch type {
        case is Bool.Type: "true or false"
        case is String.Type: "text"
        case is Int.Type, is UInt8.Type, is UInt16.Type: "a whole number"
        case is Double.Type: "a number"
        case is [Int].Type: "a list of whole numbers"
        default: "\(type)"
        }
    }
}
