import Foundation
import WebKit
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

/// Talks to truecloud.in from inside a hidden, stripped-down web view.
///
/// Since 2026-11-05 truecloud.in only answers its own website running in a browser, so the app's requests go
/// through WebKit (the engine Safari uses) on the TrueCloud origin instead of URLSession. To keep that cheap:
/// - The view opens the rig page with every script file, stylesheet, image, font and video blocked, so
///   TrueCloud's dashboard code never boots or polls. Only the 23 KB page loads. A view uses about 50 MB.
/// - Opening the page gives the view a `web_session` cookie, which every request then carries.
/// - Action ids are read from the page's script files, and which file held which ids is remembered across
///   launches. File names change only when TrueCloud deploys, so a normal launch downloads no scripts.
/// - The app's own requests (status, start, stop, pairing) are `fetch` calls made from that page.
/// - The view is torn down after two minutes without a request and rebuilt on the next one.
@MainActor
final class WebBridge: NSObject {
    static let shared = WebBridge()

    private var webView: WKWebView?
    private var pageLoadedAt: Date?
    private var pageWaiters: [CheckedContinuation<Void, Error>] = []
    private var pageLoading = false
    /// Counts page opens, so a fetch cut off by a navigation can be told apart from a real failure.
    private var pageOpens = 0
    private var idleTask: Task<Void, Never>?
    private static var rules: WKContentRuleList?

    private static let idleTimeout: Duration = .seconds(120)
    /// Re-open the page now and then so a deploy's new script names are seen.
    private static let pageMaxAge: TimeInterval = 30 * 60
    private static let cacheKey = "bridge.chunkActions"
    private static let actionPages = [TCConstants.rigPageURL, TCConstants.historyPageURL]

    // MARK: Requests

    /// Sends `request` with `fetch` from the TrueCloud page. Same shape as `HTTPTransport.send`.
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let opensBefore = pageOpens
        let data: Data, status: Int
        do {
            (data, status) = try await sendOnce(request)
        } catch TCError.network(let reason) where pageOpens != opensBefore || pageLoading {
            // The view switched pages mid-request (reading action ids from the history page), which cancels
            // the page's fetches with "Load failed". Not a real network problem: send it again.
            Log.info("[bridge] request cut off by a page switch (\(reason)); resending")
            return try await sendOnce(request)
        }
        // The web_session cookie can lapse while the view is open: get a fresh one and try once more.
        guard status == 403, String(decoding: data.prefix(200), as: UTF8.self).localizedCaseInsensitiveContains("web session")
        else { return (data, status) }
        Log.info("[bridge] web session lapsed; reopening the page")
        pageLoadedAt = nil
        return try await sendOnce(request)
    }

    private func sendOnce(_ request: URLRequest) async throws -> (Data, Int) {
        try await ensurePage()
        guard let webView, let url = request.url else { throw TCError.unexpectedResponse }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where !Self.browserOwned.contains(name.lowercased()) {
            headers[name] = value
        }
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        let args: [String: Any] = [
            "path": path.isEmpty ? "/" : path,
            "method": request.httpMethod ?? "GET",
            "headers": headers,
            "body": request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? NSNull(),
            "timeout": Int(request.timeoutInterval * 1000),
        ]
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(Self.fetchJS, arguments: args, contentWorld: .defaultClient)
        } catch {
            throw TCError.network((error as NSError).localizedDescription)
        }
        scheduleIdle()
        guard let dict = result as? [String: Any], let status = (dict["status"] as? NSNumber)?.intValue else {
            throw TCError.unexpectedResponse
        }
        if status == 0 { throw TCError.network((dict["error"] as? String) ?? "the request failed") }
        let body = (dict["body"] as? String) ?? ""
        if status >= 400 {
            let snippet = body.prefix(160).replacingOccurrences(of: "\n", with: " ")
            Log.info("[bridge] \(request.httpMethod ?? "GET") \(path) → \(status): \(snippet)")
        }
        return (Data(body.utf8), status)
    }

    /// Headers the browser sets itself (fetch refuses them, and TrueCloud gets the real ones).
    private static let browserOwned: Set<String> = ["origin", "referer", "user-agent", "content-length", "host", "cookie"]

    private static let fetchJS = """
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeout || 30000);
    try {
      // `same-origin` sends the `web_session` cookie truecloud.in set when the page opened; since 2026-11-06
      // every Server Action without it gets 403 "Browser web session required".
      const init = { method, headers, cache: 'no-store', credentials: 'same-origin', signal: ctrl.signal };
      if (body !== null && method !== 'GET') init.body = body;
      const r = await fetch(path, init);
      return { status: r.status, body: await r.text() };
    } catch (e) {
      return { status: 0, error: String(e && e.message || e) };
    } finally { clearTimeout(timer); }
    """

    // MARK: Action ids

    /// The live Server Action ids (name → id). `force` re-opens the page first (after a stale id).
    func resolveActions(force: Bool) async throws -> [String: String] {
        if force { pageLoadedAt = nil }
        var cache = (UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: [String: String]]) ?? [:]

        // The rig page holds the cloud PC actions and Activity; the history page holds Payments.
        var chunks: [String] = []
        for page in Self.actionPages {
            try await ensurePage(page)
            guard let webView else { throw TCError.actionsUnavailable }
            let listed = try await webView.callAsyncJavaScript(Self.chunkListJS, arguments: [:], contentWorld: .defaultClient)
            for chunk in (listed as? [String]) ?? [] where !chunks.contains(chunk) { chunks.append(chunk) }
        }
        guard !chunks.isEmpty, let webView else { throw TCError.actionsUnavailable }

        let missing = chunks.filter { cache[Self.fileName($0)] == nil }
        if !missing.isEmpty {
            let read = try await webView.callAsyncJavaScript(Self.chunkActionsJS, arguments: ["chunks": missing],
                                                             contentWorld: .defaultClient)
            for (path, found) in (read as? [String: [String: String]]) ?? [:] {
                cache[Self.fileName(path)] = found
            }
            Log.info("[bridge] read \(missing.count) script file\(missing.count == 1 ? "" : "s") for action ids")
        }
        // Keep only the current deploy's files.
        let current = Set(chunks.map(Self.fileName))
        cache = cache.filter { current.contains($0.key) }
        UserDefaults.standard.set(cache, forKey: Self.cacheKey)
        scheduleIdle()

        var ids: [String: String] = [:]
        for name in chunks.map(Self.fileName) { ids.merge(cache[name] ?? [:]) { current, _ in current } }
        return ids
    }

    private static func fileName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    /// Script files the page refers to (in its tags and its inline Next.js data).
    private static let chunkListJS = """
    const html = document.documentElement.outerHTML.split('\\\\/').join('/');
    return [...new Set([...html.matchAll(/\\/_next\\/static\\/chunks\\/[^"'\\\\\\s<>]+?\\.js/g)].map(m => m[0]))];
    """

    /// name → id for every Server Action reference in each file (empty for files without any).
    private static let chunkActionsJS = """
    const out = {};
    await Promise.all(chunks.map(async c => {
      const found = {};
      try {
        const r = await fetch(c, { credentials: 'omit' });
        if (r.ok) {
          const t = await r.text();
          for (const m of t.matchAll(/createServerReference\\)\\("([0-9a-f]{40,})",[^)]*?,"(\\w+)"\\)/g)) found[m[2]] = m[1];
          out[c] = found;
        }
      } catch (e) {}
    }));
    return out;
    """

    // MARK: Page

    /// Opens (or re-opens) the rig page in the hidden view and waits for it.
    /// `page` nil means any TrueCloud page will do (requests only need the origin).
    private func ensurePage(_ page: URL? = nil) async throws {
        // Another caller may be loading a different page; wait for it, then look again.
        for _ in 0..<3 {
            if webView != nil, let loaded = pageLoadedAt, Date.now.timeIntervalSince(loaded) < Self.pageMaxAge,
               page == nil || webView?.url?.path == page?.path { return }
            if !pageLoading, page != nil { pageLoadedAt = nil }
            try await loadPage(page)
        }
    }

    private func loadPage(_ page: URL?) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            pageWaiters.append(waiter)
            guard !pageLoading else { return }
            pageLoading = true
            Task {
                do { try await openPage(page ?? TCConstants.rigPageURL) } catch { pageFinished(error) }
            }
        }
    }

    private func openPage(_ page: URL) async throws {
        let view = try await makeWebViewIfNeeded()
        pageOpens += 1
        Log.info("[bridge] opening \(page.path)")
        view.load(URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    private func makeWebViewIfNeeded() async throws -> WKWebView {
        if let webView { return webView }
        if Self.rules == nil {
            Self.rules = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "truecloud-bridge", encodedContentRuleList: Self.blockList)
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // in memory only: holds the page's web_session cookie while the view lives
        config.suppressesIncrementalRendering = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        if let rules = Self.rules { config.userContentController.add(rules) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16), configuration: config)
        view.navigationDelegate = self
        webView = view
        return view
    }

    /// Everything except the HTML page and the app's own fetches: script files (so TrueCloud's dashboard never
    /// starts), styles, images, fonts, media, frames and popups.
    private static let blockList = """
    [{"trigger":{"url-filter":".*","resource-type":["script","style-sheet","image","font","media","svg-document","popup"]},
      "action":{"type":"block"}}]
    """

    private func resumeWaiters(with error: Error?) {
        let waiters = pageWaiters
        pageWaiters = []
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    private func pageFinished(_ error: Error?) {
        pageLoading = false
        if let error {
            pageLoadedAt = nil
            Log.info("[bridge] couldn't open truecloud.in: \(error.localizedDescription)")
        } else {
            pageLoadedAt = .now
        }
        resumeWaiters(with: error)
        scheduleIdle()
    }

    /// Frees the web view (and its processes) after a quiet spell.
    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    func unload() {
        guard webView != nil, !pageLoading else { return }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        pageLoadedAt = nil
        Log.info("[bridge] closed (idle)")
    }
}

extension WebBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 200
        if navigationResponse.isForMainFrame, status >= 400 {
            decisionHandler(.cancel)
            let error: TCError = status == 403
                ? .clientBlocked("Forbidden (\(status)) when opening truecloud.in")
                : .http(status)
            pageFinished(error)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard pageLoading else { return }
        pageFinished(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard pageLoading else { return }
        pageFinished(TCError.network(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard pageLoading else { return }
        pageFinished(TCError.network(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.info("[bridge] web content process ended; it will reopen on the next request")
        self.webView = nil
        pageLoadedAt = nil
        if pageLoading { pageFinished(TCError.network("the web view stopped")) }
    }
}

extension WebBridge {
    static func sendShared(_ request: URLRequest) async throws -> (Data, Int) { try await shared.send(request) }
    static func resolveShared(force: Bool) async throws -> [String: String] { try await shared.resolveActions(force: force) }

    /// `RigAPI` with every truecloud.in request going through the bridge.
    static func makeRigAPI() -> RigAPI {
        let transport = BridgeTransport()
        let resolver = ActionResolver(transport: transport, source: { force in try await WebBridge.resolveShared(force: force) })
        return RigAPI(transport: transport, resolver: resolver)
    }
}

/// `HTTPTransport` over the bridge, for `RigAPI`.
struct BridgeTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        try await WebBridge.sendShared(request)
    }
}
