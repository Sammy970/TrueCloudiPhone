import Foundation

/// Finds the current Server Action ids. Next.js changes them on every TrueCloud deploy, so the ids are
/// read from the rig page's JavaScript (`createServerReference("<id>", …, "<name>")`) and cached, with
/// the ids seen at build time as a fallback.
public actor ActionResolver {
    private let transport: HTTPTransport
    private var ids: [String: String]
    private var resolvedLive = false

    /// Reads the live ids some other way (the app's web bridge). When set, `refresh()` uses it instead of HTTP.
    public typealias Source = @Sendable (_ force: Bool) async throws -> [String: String]
    private let source: Source?

    public init(transport: HTTPTransport = URLSessionTransport(), fallback: [String: String] = TCConstants.fallbackActionIDs,
                source: Source? = nil) {
        self.transport = transport
        self.ids = fallback
        self.source = source
    }

    public func id(for action: String) throws -> String {
        guard let id = ids[action] else { throw TCError.actionsUnavailable }
        return id
    }

    public var hasResolvedLive: Bool { resolvedLive }
    public var currentIDs: [String: String] { ids }

    /// Reads the rig page and its chunks and updates the ids. Returns the names it found.
    @discardableResult
    public func refresh(force: Bool = true) async throws -> [String: String] {
        if let source {
            let found = try await source(force)
            guard !found.isEmpty else { throw TCError.actionsUnavailable }
            ids.merge(found) { _, new in new }
            resolvedLive = true
            return found
        }
        let page = try await fetchText(TCConstants.rigPageURL)
        let chunks = Self.chunkURLs(inHTML: page)
        guard !chunks.isEmpty else { throw TCError.actionsUnavailable }

        // The rig page's own chunk first (most likely to hold everything), but read them all in parallel.
        let found = await withTaskGroup(of: [String: String].self) { group in
            for path in chunks {
                group.addTask { [self] in
                    guard let url = URL(string: path, relativeTo: TCConstants.siteBase)?.absoluteURL,
                          let js = try? await fetchText(url) else { return [:] }
                    return Self.parseActions(inJS: js)
                }
            }
            var all: [String: String] = [:]
            for await part in group { all.merge(part) { current, _ in current } }
            return all
        }
        guard !found.isEmpty else { throw TCError.actionsUnavailable }
        ids.merge(found) { _, new in new }
        resolvedLive = true
        return found
    }

    // MARK: Parsing (static, for tests)

    /// `/_next/static/chunks/….js` paths mentioned by the page, with `\/` escapes undone.
    public static func chunkURLs(inHTML html: String) -> [String] {
        let text = html.replacingOccurrences(of: "\\/", with: "/")
        let regex = try! NSRegularExpression(pattern: #"/_next/static/chunks/[^"'\\\s<>]+?\.js"#)
        var seen = Set<String>()
        var result: [String] = []
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let path = String(text[Range(m.range, in: text)!])
            if seen.insert(path).inserted { result.append(path) }
        }
        return result
    }

    /// name -> id for every server reference in a chunk.
    public static func parseActions(inJS js: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"createServerReference\)\("([0-9a-f]{40,})",[^)]*,"(\w+)"\)"#)
        var result: [String: String] = [:]
        for m in regex.matches(in: js, range: NSRange(js.startIndex..., in: js)) {
            guard let id = Range(m.range(at: 1), in: js), let name = Range(m.range(at: 2), in: js) else { continue }
            result[String(js[name])] = String(js[id])
        }
        return result
    }

    private func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh) TrueCloudMac", forHTTPHeaderField: "User-Agent")
        let (data, status) = try await transport.send(request)
        if let blocked = TCError.blockedClient(status: status, body: data) { throw blocked }
        guard (200..<300).contains(status) else { throw TCError.http(status) }
        return String(decoding: data, as: UTF8.self)
    }
}
