import Foundation

/// A command's failure as the user sees it: one line on stderr, led by the program name, and a
/// non-zero exit status (`docs/ui-language.md`, CLI).
enum CLIError {
    /// "puremouse: can't register: reason".
    static func line(_ what: String, _ reason: Any) -> String { "puremouse: \(what): \(reason)" }

    static func fail(_ what: String, _ reason: Any, status: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((line(what, reason) + "\n").utf8))
        exit(status)
    }
}
