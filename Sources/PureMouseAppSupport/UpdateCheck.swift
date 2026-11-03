import Foundation

/// The GET of the latest GitHub release, compared with this app's version: on demand from
/// Settings › About (`fetch`), and once a day in the menu bar app when the person allows it
/// (`fetchScheduled`, driven by `UpdateReminders`). The logic is pure (`Version`, `parse`, `request`);
/// `urlSession` is the only network code, and a test injects a `Fetcher` in its place.
public enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/mblauberg/PureMouse/releases/latest")!

    public struct Release: Equatable, Sendable {
        public var version: Version
        public var page: URL

        public init(version: Version, page: URL) {
            self.version = version
            self.page = page
        }
    }

    /// Performs a request; throws when none was answered. Tests pass their own, so none reaches GitHub.
    public typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// What a scheduled check learned.
    public enum Scheduled: Equatable, Sendable {
        /// 304: the release is the one the last ETag named.
        case notModified
        /// 200: the latest release and the ETag that names it, if GitHub sent one.
        case latest(Release, etag: String?)
        case failed
    }

    public enum Outcome: Equatable, Sendable {
        case upToDate
        case available(Release)
        case failed
    }

    public struct Version: Comparable, Equatable, Sendable {
        public var parts: [Int]

        /// "v1.2.3" or "1.2.3" (a pre-release or build suffix after the numbers is ignored).
        public init?(_ text: String) {
            var text = Substring(text.trimmingCharacters(in: .whitespaces))
            if text.first == "v" || text.first == "V" { text = text.dropFirst() }
            let core = text.prefix { $0.isNumber || $0 == "." }
            let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
            parts = numbers.compactMap { $0 }
        }

        public static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) {
                let x = i < a.parts.count ? a.parts[i] : 0
                let y = i < b.parts.count ? b.parts[i] : 0
                if x != y { return x < y }
            }
            return false
        }

        public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

        /// "1.2.3": the numbers, as the notification and the menu say them.
        public var text: String { parts.map(String.init).joined(separator: ".") }
    }

    /// The release in a `releases/latest` response; nil when it is not one (drafts and
    /// pre-releases are never "latest", but a malformed body must not read as an update).
    static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, let version = Version(tag),
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              isReleasePage(page) else { return nil }
        return Release(version: version, page: page)
    }

    /// Only this project's own release pages are trusted to be opened, whatever the response says:
    /// `/mblauberg/PureMouse/releases` and what lies below it, with no `.` or `..` component to climb out.
    static func isReleasePage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil else { return false }
        let components = url.pathComponents  // "/" first; percent-encoding is already decoded
        return components.count >= 4 && Array(components[0..<4]) == ["/", "mblauberg", "PureMouse", "releases"]
            && !components.contains { $0 == ".." || $0 == "." }
    }

    static func outcome(current: String, data: Data) -> Outcome {
        guard let release = parse(data) else { return .failed }
        guard let current = Version(current) else { return .available(release) }
        return release.version > current ? .available(release) : .upToDate
    }

    /// The request for the latest release. `scheduled` (the daily check) refuses constrained and
    /// expensive networks (Low Data Mode, a metered hotspot) and, once an ETag is known, asks only
    /// whether the release changed (`If-None-Match`). The on-demand check sends neither.
    static func request(scheduled: Bool = false, etag: String? = nil) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard scheduled else { return request }
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = false
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// An ephemeral session, so no cookies or cache are kept.
    public static let urlSession: Fetcher = { request in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public static func fetch(current: String, fetcher: Fetcher = urlSession) async -> Outcome {
        guard let (data, response) = try? await fetcher(request()), response.statusCode == 200 else { return .failed }
        return outcome(current: current, data: data)
    }

    /// The daily check: a 304 is "no change", a 200 the release and its ETag, anything else a failure.
    public static func fetchScheduled(etag: String?, fetcher: Fetcher = urlSession) async -> Scheduled {
        guard let (data, response) = try? await fetcher(request(scheduled: true, etag: etag)) else { return .failed }
        switch response.statusCode {
        case 304: return .notModified
        case 200:
            guard let release = parse(data) else { return .failed }
            return .latest(release, etag: response.value(forHTTPHeaderField: "ETag"))
        default: return .failed
        }
    }
}
