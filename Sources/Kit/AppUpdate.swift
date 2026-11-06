import Foundation

/// The newest published release of this app, read from GitHub's "latest release" API.
public struct AppRelease: Equatable, Sendable {
    public let version: String
    public let pageURL: URL
    public let publishedAt: Date?

    /// Reads one GitHub release object. Drafts and pre-releases are skipped (nil), like `/releases/latest` does.
    public init?(json: Any?) {
        guard let dict = json as? [String: Any],
              dict["draft"] as? Bool != true, dict["prerelease"] as? Bool != true,
              let tag = dict["tag_name"] as? String,
              let version = AppVersion.normalized(tag),
              let page = (dict["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        self.version = version
        self.pageURL = page
        self.publishedAt = (dict["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    public init(version: String, pageURL: URL, publishedAt: Date? = nil) {
        self.version = version
        self.pageURL = pageURL
        self.publishedAt = publishedAt
    }
}

/// Dotted version numbers ("0.1.2", tags like "v0.1.2").
public enum AppVersion {
    /// "v0.1.2" → "0.1.2"; nil for anything that isn't numbers separated by dots.
    public static func normalized(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.first == "v" || t.first == "V" { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return t
    }

    /// Whether `candidate` is a later version than `current`. "0.1.10" is later than "0.1.9"; "0.2" equals "0.2.0".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = normalized(candidate), let b = normalized(current) else { return false }
        let x = a.split(separator: ".").compactMap { Int($0) }
        let y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Asks GitHub for the latest release of an app ("owner/name", e.g. "Sammy970/TrueCloudMac").
public struct UpdateClient: Sendable {
    public let latestURL: URL
    private let transport: HTTPTransport

    public init(repository: String, transport: HTTPTransport = URLSessionTransport()) {
        self.latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        self.transport = transport
    }

    /// The latest release, or nil when there's none yet.
    public func latest() async throws -> AppRelease? {
        var request = URLRequest(url: latestURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TrueCloud-update-check", forHTTPHeaderField: "User-Agent")
        let (data, status) = try await transport.send(request)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw TCError.http(status) }
        return AppRelease(json: try? JSONSerialization.jsonObject(with: data))
    }
}
