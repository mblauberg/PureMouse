import Foundation

/// A command's failure as the user sees it: one line on stderr, led by the program name, and a
/// non-zero exit status (`docs/ui-language.md`, CLI).
enum CLIError {
    /// "puremouse: can't register: reason". A reason that runs over several lines (launchctl's
    /// output) is joined into one, so every line of stderr leads with the program name.
    static func line(_ what: String, _ reason: Any) -> String {
        let oneLine = "\(reason)".split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        return "puremouse: \(what): \(oneLine)"
    }

    static func fail(_ what: String, _ reason: Any, status: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((line(what, reason) + "\n").utf8))
        exit(status)
    }
}
