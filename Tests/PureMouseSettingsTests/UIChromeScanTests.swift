import Foundation
import Testing

// docs/ui-design.md, "Forms and controls" (Let the system draw; Custom shapes are concentric):
// Settings sets no font size, control size, background, material or colour literal, so the
// system draws the chrome at whatever size and appearance it has (macOS 26's taller controls,
// Increase Contrast, Reduce Transparency, Liquid Glass). This reads `Sources/PureMouseSettingsUI`
// through `#filePath`, as `AboutLinksTests` does, and fails on what it finds outside the
// allow-list. A stale allow-list entry fails too, so the list only ever shrinks.

/// One thing the scan rejects, and where.
struct ChromeViolation: Equatable, CustomStringConvertible {
    let line: Int
    let rule: String
    var description: String { "line \(line): \(rule)" }
}

/// A line the scan lets through, and why. `fragment` is an exact piece of the source line.
struct ChromeAllowance {
    let file: String
    let fragment: String
    let reason: String
}

enum ChromeScan {
    /// At most this many allow-list entries.
    static let allowanceLimit = 5

    // MARK: Stripping

    /// `source` with comments and string literals (their quotes included) blanked to spaces,
    /// newlines kept, so a pattern is never found in prose and offsets still give line numbers.
    static func stripped(_ source: String) -> String {
        let chars = Array(source)
        var out = [Character](repeating: " ", count: chars.count)
        for (i, c) in chars.enumerated() where c == "\n" { out[i] = "\n" }
        var i = 0
        func at(_ j: Int) -> Character? { j < chars.count ? chars[j] : nil }
        while i < chars.count {
            let c = chars[i]
            if c == "/", at(i + 1) == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", at(i + 1) == "*" {
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if chars[i] == "/", at(i + 1) == "*" { depth += 1; i += 2 }
                    else if chars[i] == "*", at(i + 1) == "/" { depth -= 1; i += 2 }
                    else { i += 1 }
                }
            } else if c == "\"" || (c == "#" && isRawStringStart(chars, i)) {
                i = skipString(chars, from: i)
            } else {
                out[i] = c
                i += 1
            }
        }
        return String(out)
    }

    private static func isRawStringStart(_ chars: [Character], _ start: Int) -> Bool {
        var j = start
        while j < chars.count, chars[j] == "#" { j += 1 }
        return j < chars.count && chars[j] == "\""
    }

    /// The index after the string literal that starts at `start` (`"…"`, `"""…"""`, `#"…"#`),
    /// interpolations skipped whole.
    private static func skipString(_ chars: [Character], from start: Int) -> Int {
        var hashes = 0
        var i = start
        while i < chars.count, chars[i] == "#" { hashes += 1; i += 1 }
        let multiline = i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\""
        i += multiline ? 3 : 1
        let closing = String(repeating: "#", count: hashes)
        func hasClosing(at j: Int) -> Bool {
            let needed = (multiline ? "\"\"\"" : "\"") + closing
            return Array(needed).enumerated().allSatisfy { j + $0.offset < chars.count && chars[j + $0.offset] == $0.element }
        }
        while i < chars.count {
            if hasClosing(at: i) { return i + (multiline ? 3 : 1) + hashes }
            if chars[i] == "\\", Array(String(repeating: "#", count: hashes)).enumerated()
                .allSatisfy({ i + 1 + $0.offset < chars.count && chars[i + 1 + $0.offset] == "#" }),
               i + 1 + hashes < chars.count, chars[i + 1 + hashes] == "(" {
                var depth = 1
                i += 2 + hashes
                while i < chars.count, depth > 0 {
                    if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                    else if chars[i] == "\"" { i = skipString(chars, from: i) - 1 }
                    i += 1
                }
            } else if chars[i] == "\\", hashes == 0 {
                i += 2
            } else if chars[i] == "\n", !multiline {
                return i // unterminated: stop at the line
            } else {
                i += 1
            }
        }
        return i
    }

    // MARK: Rules

    private static let lineRules: [(rule: String, pattern: String)] = [
        (".system(size:", #"\.system\(\s*size\s*:"#),
        (".background(", #"\.background\("#),
        (".background {", #"\.background\s*\{"#),
        ("Color(<values>)", #"\bColor\(\s*(red|hue|white|cgColor)\s*:"#),
        (".custom(", #"\.custom\("#),
        ("Material", #"\bMaterial\b|\.(ultraThin|thin|regular|thick|ultraThick|bar)Material\b"#),
        ("NSVisualEffectView", #"\bNSVisualEffectView\b"#),
        ("glassEffect", #"\bglassEffect\b"#),
        (".buttonStyle(.glass", #"\.buttonStyle\(\s*\.glass"#),
        ("cornerRadius", #"cornerRadius"#),
        ("RoundedRectangle(", #"\bRoundedRectangle\("#),
        ("Color.<name>", #"\bColor\.(?!clear\b|primary\b|secondary\b)[A-Za-z]"#),
        ("named colour",
         #"\.(red|green|yellow|orange|blue|purple|pink|brown|gray|grey|teal|mint|cyan|indigo|white|black)\b"#),
    ]

    private static let frameKeys: Set<String> = [
        "width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight", "idealWidth", "idealHeight",
    ]

    /// Everything the scan rejects in `source`.
    static func violations(in source: String) -> [ChromeViolation] {
        let text = stripped(source)
        let chars = Array(text)
        var found: [ChromeViolation] = []

        func line(of offset: Int) -> Int { chars[..<offset].filter { $0 == "\n" }.count + 1 }

        for (rule, pattern) in lineRules {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let offset = text.distance(from: text.startIndex, to: Range(match.range, in: text)!.lowerBound)
                found.append(ChromeViolation(line: line(of: offset), rule: rule))
            }
        }

        // A .frame( with a number for any size: the arguments, split at top-level commas.
        var search = text.startIndex
        while let range = text.range(of: ".frame(", range: search..<text.endIndex) {
            search = range.upperBound
            let offset = text.distance(from: text.startIndex, to: range.upperBound)
            for argument in arguments(chars, from: offset) {
                guard let colon = argument.firstIndex(of: ":") else { continue }
                let key = argument[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = argument[argument.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if frameKeys.contains(key), isNumeric(value) {
                    found.append(ChromeViolation(line: line(of: offset), rule: ".frame(\(key): \(value))"))
                }
            }
        }

        // .controlSize( only as .mini on a Toggle.
        let controlSize = try! NSRegularExpression(pattern: #"\.controlSize\(([^)]*)\)"#)
        let lines = text.components(separatedBy: "\n")
        for match in controlSize.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let start = Range(match.range, in: text)!.lowerBound
            let offset = text.distance(from: text.startIndex, to: start)
            let number = line(of: offset)
            let argument = Range(match.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
            let nearby = lines[max(number - 8, 0)..<number].joined(separator: "\n")
            if argument == ".mini", nearby.contains("Toggle(") { continue }
            found.append(ChromeViolation(line: number, rule: ".controlSize(\(argument ?? ""))"))
        }
        return found.sorted { ($0.line, $0.rule) < ($1.line, $1.rule) }
    }

    /// The top-level arguments of the call whose `(` is just before `offset`.
    private static func arguments(_ chars: [Character], from offset: Int) -> [String] {
        var depth = 1
        var current = ""
        var result: [String] = []
        var i = offset
        while i < chars.count {
            let c = chars[i]
            if "([{".contains(c) { depth += 1 }
            if ")]}".contains(c) {
                depth -= 1
                if depth == 0 { break }
            }
            if c == ",", depth == 1 {
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        result.append(current)
        return result
    }

    /// A number, or arithmetic starting with one, or `CGFloat(` of one. A name is not: a constant
    /// such as `SettingsWindowController.sheetWidth` has an owner, and `.infinity` is flexible.
    private static func isNumeric(_ value: String) -> Bool {
        let value = value.hasPrefix("CGFloat(") ? String(value.dropFirst("CGFloat(".count)) : value
        guard let first = value.first else { return false }
        return first.isNumber || (first == "." && value.dropFirst().first?.isNumber == true) || first == "-"
    }

    // MARK: Allow-list

    /// What is wrong with `files` (name to source) given `allowed`: each violation not allowed, each
    /// stale entry, and too many entries. Empty means the sources are clean.
    static func problems(files: [String: String], allowed: [ChromeAllowance]) -> [String] {
        var problems: [String] = []
        if allowed.count > allowanceLimit {
            problems.append("\(allowed.count) allow-list entries; at most \(allowanceLimit)")
        }
        var used = Set<Int>()
        for (name, source) in files.sorted(by: { $0.key < $1.key }) {
            let lines = source.components(separatedBy: "\n")
            for violation in violations(in: source) {
                let text = lines.indices.contains(violation.line - 1) ? lines[violation.line - 1] : ""
                let hits = allowed.indices.filter { allowed[$0].file == name && text.contains(allowed[$0].fragment) }
                if hits.isEmpty {
                    problems.append("\(name) \(violation): \(text.trimmingCharacters(in: .whitespaces))")
                } else {
                    used.formUnion(hits)
                }
            }
        }
        for (index, entry) in allowed.enumerated() where !used.contains(index) {
            problems.append("stale allow-list entry: \(entry.file) \"\(entry.fragment)\"")
        }
        for entry in allowed where entry.reason.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("allow-list entry without a reason: \(entry.file) \"\(entry.fragment)\"")
        }
        return problems
    }
}

@Suite struct UIChromeScan {
    private static let ui = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI")

    /// Every Settings source, by file name.
    private static func sources() throws -> [String: String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: ui.path).filter { $0.hasSuffix(".swift") }
        var files: [String: String] = [:]
        for name in names { files[name] = try String(contentsOf: ui.appending(path: name), encoding: .utf8) }
        return files
    }

    /// Where the system cannot size a thing itself. At most `ChromeScan.allowanceLimit` entries;
    /// anything else is removed from the source.
    static let allowed = [
        ChromeAllowance(
            file: "AboutPane.swift", fragment: ".frame(width: 112",
            reason: "The app icon is artwork: a bitmap drawn at the Finder's size, its squircle at 824 of 1024 points."),
        ChromeAllowance(
            file: "ActionPicker.swift", fragment: ".frame(width: 260, height: 464)",
            reason: "A List has no size of its own, so the popover needs one width and height; the search field and rows are the system's."),
        ChromeAllowance(
            file: "Components.swift", fragment: ".frame(width: 200)",
            reason: "Every slider is one width, so a pane's tracks line up whatever their labels, as in System Settings."),
        ChromeAllowance(
            file: "Components.swift", fragment: ".frame(minWidth: 56, alignment: .trailing)",
            reason: "A slider's readout column is one width, so rows with short and long values (2.2, 300 ms) keep their tracks in line."),
        ChromeAllowance(
            file: "Sheets.swift", fragment: ".frame(width: 400)",
            reason: "The shortcut and command editors open as popovers inside an app's sheet, so they are narrower than the sheet; text fields have no width of their own."),
    ]

    @Test func theSettingsSourcesLetTheSystemDrawTheChrome() throws {
        let problems = ChromeScan.problems(files: try Self.sources(), allowed: Self.allowed)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func theAllowListIsShortAndEachEntryGivesItsReason() {
        #expect(Self.allowed.count <= ChromeScan.allowanceLimit)
        #expect(Self.allowed.allSatisfy { !$0.reason.isEmpty })
    }

    // MARK: The scan itself

    @Test func itRejectsEachPatternItIsMeantTo() {
        let cases: [(String, String)] = [
            (#"Text("x").font(.system(size: 12))"#, ".system(size:"),
            ("Color.clear.frame(width: 20)", ".frame(width: 20)"),
            ("view.frame(height: 22)", ".frame(height: 22)"),
            ("view.frame(minWidth: 52, alignment: .trailing)", ".frame(minWidth: 52)"),
            ("view.frame(maxWidth: .infinity, minHeight: 36)", ".frame(minHeight: 36)"),
            ("view.frame(idealHeight: 420)", ".frame(idealHeight: 420)"),
            ("view.frame(\n  width: 12.5,\n  height: 3)", ".frame(width: 12.5)"),
            ("view.controlSize(.large)", ".controlSize(.large)"),
            ("Button(\"x\") {}.controlSize(.mini)", ".controlSize(.mini)"),
            ("view.background(.background)", ".background("),
            ("view.background { Color.clear }", ".background {"),
            ("Color(red: 1, green: 0, blue: 0)", "Color(<values>)"),
            ("Color(hue: 0.5, saturation: 1, brightness: 1)", "Color(<values>)"),
            (#"Text("x").font(.custom("Menlo", size: 12))"#, ".custom("),
            ("view.background(.ultraThinMaterial)", "Material"),
            ("NSVisualEffectView()", "NSVisualEffectView"),
            ("view.glassEffect()", "glassEffect"),
            ("view.buttonStyle(.glass)", ".buttonStyle(.glass"),
            ("view.buttonStyle(.glassProminent)", ".buttonStyle(.glass"),
            ("shape.cornerRadius(4)", "cornerRadius"),
            ("RoundedRectangle(cornerRadius: 7)", "RoundedRectangle("),
            ("Color.accentColor", "Color.<name>"),
            ("Color.red", "Color.<name>"),
            ("view.foregroundStyle(.white)", "named colour"),
            ("view.foregroundStyle(.black)", "named colour"),
            ("view.tint(.yellow)", "named colour"),
            ("view.foregroundStyle(.green)", "named colour"),
            ("view.foregroundStyle(.red)", "named colour"),
        ]
        for (source, rule) in cases {
            let rules = ChromeScan.violations(in: source).map(\.rule)
            #expect(rules.contains(rule), "\(source) should be rejected as \(rule), got \(rules)")
        }
    }

    @Test func itAcceptsWhatTheSystemDrawsAndTheForm() {
        let clean = """
        Text("x").font(.title3).foregroundStyle(.secondary)
        Color.clear
        Color.primary
        Color.secondary
        view.frame(maxWidth: .infinity, alignment: .leading)
        view.frame(width: SettingsWindowController.sheetWidth)
        view.frame(width: size, height: size)
        Toggle("x", isOn: $on)
            .controlSize(.mini)
        view.imageScale(.small)
        view.listRowBackground(rowFill)
        view.foregroundStyle(.tint)
        """
        #expect(ChromeScan.violations(in: clean) == [])
    }

    @Test func itIgnoresCommentsAndStringLiterals() {
        let source = #"""
        // .font(.system(size: 9)) and Color.red and .frame(width: 20)
        /* .background(.white)
           /* nested .frame(height: 3) */ RoundedRectangle( */
        let a = "Color.red .system(size: 9) // not a comment"
        let b = "say \"hi\" .white"
        let c = "interpolated \(value.map { "nested .white" }) .red"
        let d = #"raw "quoted" .green"#
        let e = """
            multi-line .frame(width: 3)
            .background(.red)
            """
        let f = 1
        """#
        #expect(ChromeScan.violations(in: source) == [])
        // A violation after a string on the same line, and the line numbers, still count.
        #expect(ChromeScan.violations(in: "let a = \"x\"\nlet b = \"y\"; view.frame(width: 4)")
            == [ChromeViolation(line: 2, rule: ".frame(width: 4)")])
    }

    @Test func anAllowedLineIsLetThroughByItsFragment() {
        let files = ["A.swift": "view.frame(width: 112, height: 112)\nview.frame(width: 9)\n"]
        let entry = ChromeAllowance(file: "A.swift", fragment: ".frame(width: 112", reason: "artwork")
        let problems = ChromeScan.problems(files: files, allowed: [entry])
        #expect(problems.count == 1 && problems[0].contains("width: 9"))
        // The same fragment in another file allows nothing there.
        #expect(!ChromeScan.problems(files: ["B.swift": "view.frame(width: 112)"], allowed: [entry]).isEmpty)
    }

    @Test func aStaleAllowListEntryFails() {
        let entry = ChromeAllowance(file: "A.swift", fragment: ".frame(width: 112", reason: "artwork")
        let problems = ChromeScan.problems(files: ["A.swift": "view.frame(maxWidth: .infinity)"], allowed: [entry])
        #expect(problems.count == 1 && problems[0].hasPrefix("stale allow-list entry"))
    }

    @Test func moreThanFiveEntriesFail() {
        let entries = (0..<6).map { ChromeAllowance(file: "A.swift", fragment: ".frame(width: \($0)", reason: "r") }
        let source = (0..<6).map { "view.frame(width: \($0))" }.joined(separator: "\n")
        let problems = ChromeScan.problems(files: ["A.swift": source], allowed: entries)
        #expect(problems == ["6 allow-list entries; at most 5"])
    }

    @Test func anEntryWithoutAReasonFails() {
        let entry = ChromeAllowance(file: "A.swift", fragment: ".frame(width: 1", reason: " ")
        #expect(ChromeScan.problems(files: ["A.swift": "view.frame(width: 1)"], allowed: [entry]).count == 1)
    }

    // MARK: Tooltips

    /// A `.help("…")` literal is under 75 characters (docs/ui-language.md). Dynamic tooltips are
    /// capped where they are built (`ActionButton.tooltip(for:)`).
    @Test func everyTooltipLiteralIsUnder75Characters() throws {
        let help = try NSRegularExpression(pattern: #"\.help\("((?:[^"\\\n]|\\.)*)"\)"#)
        var offenders: [String] = []
        for (name, source) in try Self.sources() {
            for match in help.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let text = String(source[Range(match.range(at: 1), in: source)!])
                if text.count >= 75 { offenders.append("\(name): \(text)") }
            }
        }
        #expect(offenders == [])
    }
}
