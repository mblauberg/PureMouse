import Foundation

/// "Check for Updates", on demand only: one GET of the latest GitHub release, compared with this
/// app's version. The logic is pure (`Version`, `parse`); `fetch` is the only network code.
enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/mblauberg/PureMouse/releases/latest")!

    struct Release: Equatable {
        var version: Version
        var page: URL
    }

    enum Outcome: Equatable {
        case upToDate
        case available(Release)
        case failed
    }

    struct Version: Comparable, Equatable {
        var parts: [Int]

        /// "v1.2.3" or "1.2.3" (a pre-release or build suffix after the numbers is ignored).
        init?(_ text: String) {
            var text = Substring(text.trimmingCharacters(in: .whitespaces))
            if text.first == "v" || text.first == "V" { text = text.dropFirst() }
            let core = text.prefix { $0.isNumber || $0 == "." }
            let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
            parts = numbers.compactMap { $0 }
        }

        static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) {
                let x = i < a.parts.count ? a.parts[i] : 0
                let y = i < b.parts.count ? b.parts[i] : 0
                if x != y { return x < y }
            }
            return false
        }

        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
    }

    /// The release in a `releases/latest` response; nil when it is not one (drafts and
    /// pre-releases are never "latest", but a malformed body must not read as an update).
    static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, let version = Version(tag),
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https" else { return nil }
        return Release(version: version, page: page)
    }

    static func outcome(current: String, data: Data) -> Outcome {
        guard let release = parse(data) else { return .failed }
        guard let current = Version(current) else { return .available(release) }
        return release.version > current ? .available(release) : .upToDate
    }

    static func fetch(current: String) async -> Outcome {
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
        return outcome(current: current, data: data)
    }
}
