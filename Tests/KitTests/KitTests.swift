import XCTest
@testable import TrueCloudKit

/// Scripted transport: returns canned answers in order and records requests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(Data, Int)]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [(String, Int)]) { queue = responses.map { (Data($0.0.utf8), $0.1) } }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return queue.isEmpty ? (Data(), 500) : queue.removeFirst()
    }
}

final class FirestoreTests: XCTestCase {
    static let doc = """
    {"name":"projects/x/databases/(default)/documents/users/u1","fields":{
      "displayName":{"stringValue":"Samyak Jain"},"photoURL":{"stringValue":"https://x/y.png"},
      "node":{"stringValue":"truecloud-2"},"vmid":{"stringValue":"754"},
      "moonlight_ip":{"stringValue":"moonlight-a2.truecloud.in"},
      "sunshine_port":{"stringValue":"moonlight-a2.truecloud.in:35451"},
      "currentplan":{"stringValue":"Basic "},"time_remain":{"integerValue":"14220000"},
      "time_plan":{"stringValue":"36000000"},"daily_limit":{"doubleValue":7200000},
      "night_plan":{"booleanValue":false},"subscription":{"booleanValue":true},"auto_renew":{"booleanValue":true},
      "provisioningStatus":{"stringValue":"ready"},"hasPairedBefore":{"booleanValue":true},
      "expiration":{"timestampValue":"2026-12-01T10:00:00.5Z"}}}
    """

    func testParsesFixture() throws {
        let json = try JSONSerialization.jsonObject(with: Data(Self.doc.utf8)) as! [String: Any]
        let p = try RigProfile.parse(document: json, uid: "u1")
        XCTAssertEqual(p.node, "truecloud-2")
        XCTAssertEqual(p.vmid, 754)
        XCTAssertEqual(p.moonlightHost, "moonlight-a2.truecloud.in")
        XCTAssertEqual(p.sunshineAddress, "moonlight-a2.truecloud.in:35451")
        XCTAssertEqual(p.planName, "Basic")
        XCTAssertEqual(p.hoursRemaining, 3.95, accuracy: 0.001)
        XCTAssertEqual(p.planHours, 10, accuracy: 0.001)
        XCTAssertEqual(p.dailyLimitHours, 2, accuracy: 0.001)
        XCTAssertEqual(p.minutesLeft, 237)
        XCTAssertTrue(p.subscription && p.autoRenew && p.hasPairedBefore && !p.nightPlan)
        XCTAssertNotNil(p.expiration)
        XCTAssertFalse(p.isUnlimited)
    }

    func testVmidAsIntegerAndSunshinePortVariants() throws {
        let json = ["fields": ["node": ["stringValue": "n"], "vmid": ["integerValue": "9"],
                               "moonlight_ip": ["stringValue": "h.example"], "sunshine_port": ["integerValue": "35451"]]] as [String: Any]
        let p = try RigProfile.parse(document: json, uid: "u")
        XCTAssertEqual(p.vmid, 9)
        XCTAssertEqual(p.sunshineAddress, "h.example:35451")
        let none = try RigProfile.parse(document: ["fields": ["node": ["stringValue": "n"], "vmid": ["stringValue": "9"],
                                                              "moonlight_ip": ["stringValue": "h.example"]]], uid: "u")
        XCTAssertEqual(none.sunshineAddress, "h.example:35451")
    }

    /// Every account has its own Moonlight port (the dashboard shows "<host>:<moonlight_port>"), so it must be read, not assumed.
    func testMoonlightPortIsPerAccount() throws {
        let forms: [[String: Any]] = [["integerValue": "36450"], ["stringValue": "36450"], ["doubleValue": 36450]]
        for value in forms {
            let p = try RigProfile.parse(document: ["fields": ["node": ["stringValue": "n"], "vmid": ["stringValue": "9"],
                                                              "moonlight_ip": ["stringValue": "moonlight-a4.truecloud.in"],
                                                              "moonlight_port": value]], uid: "u")
            XCTAssertEqual(p.moonlightPort, 36450)
            XCTAssertEqual(p.moonlightHost, "moonlight-a4.truecloud.in")
            // No sunshine_port in the profile: it sits one above this account's Moonlight port, not the default's
            XCTAssertEqual(p.sunshineAddress, "moonlight-a4.truecloud.in:36451")
        }
        // A stored sunshine_port still wins
        let stored = try RigProfile.parse(document: ["fields": ["node": ["stringValue": "n"], "vmid": ["stringValue": "9"],
                                                                "moonlight_ip": ["stringValue": "h.example"], "moonlight_port": ["integerValue": "36450"],
                                                                "sunshine_port": ["stringValue": "h.example:40000"]]], uid: "u")
        XCTAssertEqual(stored.moonlightPort, 36450)
        XCTAssertEqual(stored.sunshineAddress, "h.example:40000")
        // A profile without moonlight_port falls back to the defaults
        let none = try RigProfile.parse(document: ["fields": ["node": ["stringValue": "n"], "vmid": ["stringValue": "9"],
                                                              "moonlight_ip": ["stringValue": "h.example"]]], uid: "u")
        XCTAssertEqual(none.moonlightPort, TCConstants.streamPort)
        XCTAssertEqual(none.sunshineAddress, "h.example:\(TCConstants.sunshinePort)")
        // And a profile built in code (previews, tests) defaults the same way
        XCTAssertEqual(RigProfile(uid: "u", node: "n", vmid: 1, moonlightHost: "h.example").moonlightPort, TCConstants.streamPort)
        XCTAssertEqual(RigProfile(uid: "u", node: "n", vmid: 1, moonlightHost: "h.example", moonlightPort: 36450).sunshineAddress, "h.example:36451")
    }

    /// Checks the dashboard applies before Start, matched by the client.
    func testStartGateFacts() throws {
        let base: [String: Any] = ["node": ["stringValue": "n"], "vmid": ["stringValue": "9"], "moonlight_ip": ["stringValue": "h.example"]]
        // No provisioningStatus: the dashboard treats the rig as ready
        let plain = try RigProfile.parse(document: ["fields": base], uid: "u")
        XCTAssertEqual(plain.provisioningStatus, "ready")
        XCTAssertTrue(plain.isProvisioned)
        var building = base; building["provisioningStatus"] = ["stringValue": "cloning"]
        XCTAssertFalse(try RigProfile.parse(document: ["fields": building], uid: "u").isProvisioned)
        // Times are always milliseconds, as the dashboard divides them: 500 ms is not 500 hours
        var tiny = base; tiny["time_remain"] = ["integerValue": "500"]; tiny["time_plan"] = ["integerValue": "21600000"]
        let low = try RigProfile.parse(document: ["fields": tiny], uid: "u")
        XCTAssertEqual(low.hoursRemaining, 500.0 / 3_600_000, accuracy: 1e-9)
        XCTAssertFalse(low.hasEnoughTimeToStart)
        // Expiry
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = RigProfile(uid: "u", node: "n", vmid: 1, moonlightHost: "h", expiration: now.addingTimeInterval(-60))
        let future = RigProfile(uid: "u", node: "n", vmid: 1, moonlightHost: "h", expiration: now.addingTimeInterval(60))
        let none = RigProfile(uid: "u", node: "n", vmid: 1, moonlightHost: "h")
        XCTAssertTrue(past.isExpired(at: now))
        XCTAssertFalse(future.isExpired(at: now))
        XCTAssertFalse(none.isExpired(at: now))
    }

    /// The dashboard marks the account as paired after a PIN is accepted; only that field is written.
    func testMarkPairedBeforeWritesOnlyThatField() async throws {
        let t = MockTransport([("{}", 200), ("{}", 403)])
        try await FirestoreClient(transport: t).markPairedBefore(uid: "u1", idToken: "TK")
        let request = t.requests[0]
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/documents/users/u1?updateMask.fieldPaths=hasPairedBefore"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TK")
        XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self), #"{"fields":{"hasPairedBefore":{"booleanValue":true}}}"#)
        do { try await FirestoreClient(transport: t).markPairedBefore(uid: "u1", idToken: "TK"); XCTFail("403 should throw") }
        catch { XCTAssertEqual(error as? TCError, .sessionExpired) }
    }

    /// GET /api/system-controls, as TrueCloud serves it (shape seen live).
    func testSystemControls() async {
        let live = #"{"supportEnabled":false,"startButtonEnabled":true,"startButtonDisabledReason":"paused","resetButtonEnabled":false}"#
        let on = await RigAPI(transport: MockTransport([(live, 200)])).systemControls()
        XCTAssertEqual(on, SystemControls(startEnabled: true, startDisabledReason: "paused"))
        let off = await RigAPI(transport: MockTransport([(#"{"startButtonEnabled":false,"startButtonDisabledReason":"Maintenance"}"#, 200)])).systemControls()
        XCTAssertEqual(off, SystemControls(startEnabled: false, startDisabledReason: "Maintenance"))
        // A read that fails never blocks a start (the server enforces the pause anyway)
        let failed = await RigAPI(transport: MockTransport([("oops", 500)])).systemControls()
        XCTAssertNil(failed)
        let garbage = await RigAPI(transport: MockTransport([("not json", 200)])).systemControls()
        XCTAssertNil(garbage)
    }

    func testMissingRigThrows() {
        XCTAssertThrowsError(try RigProfile.parse(document: ["fields": ["displayName": ["stringValue": "x"]]], uid: "u")) {
            XCTAssertEqual($0 as? TCError, .profileMissing)
        }
    }

    func testUnlimitedAndTimeGate() {
        var p = RigProfile(uid: "u", node: "n", vmid: 1, moonlightHost: "h", hoursRemaining: 0.01, planHours: 500)
        XCTAssertTrue(p.isUnlimited); XCTAssertTrue(p.hasEnoughTimeToStart); XCTAssertNil(p.minutesLeft)
        p.planHours = 10
        XCTAssertFalse(p.hasEnoughTimeToStart)
    }

    func testClientSendsBearerToken() async throws {
        let t = MockTransport([(Self.doc, 200)])
        let p = try await FirestoreClient(transport: t).profile(uid: "u1", idToken: "TOKEN")
        XCTAssertEqual(p.vmid, 754)
        let r = t.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "https://firestore.googleapis.com/v1/projects/truecloud-866c9/databases/(default)/documents/users/u1")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN")
    }

    func testClientErrors() async {
        for (status, expected) in [(401, TCError.sessionExpired), (404, .profileMissing), (500, .http(500))] {
            do {
                _ = try await FirestoreClient(transport: MockTransport([("{}", status)])).profile(uid: "u", idToken: "t")
                XCTFail()
            } catch { XCTAssertEqual(error as? TCError, expected) }
        }
    }
}

final class FirebaseTests: XCTestCase {
    func testSignInRequestAndParse() async throws {
        let t = MockTransport([(#"{"idToken":"I","refreshToken":"R","localId":"U","expiresIn":"3600"}"#, 200)])
        let now = Date(timeIntervalSince1970: 1000)
        let tokens = try await FirebaseAuth(transport: t, now: { now }).signIn(email: "a@b.c", password: "pw")
        XCTAssertEqual(tokens, AuthTokens(idToken: "I", refreshToken: "R", uid: "U", expiresAt: now.addingTimeInterval(3600)))
        let r = t.requests[0]
        XCTAssertTrue(r.url!.absoluteString.hasPrefix("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIza"))
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        XCTAssertEqual(body["returnSecureToken"] as? Bool, true)
        XCTAssertEqual(body["email"] as? String, "a@b.c")
    }

    func testRefreshRequestAndParse() async throws {
        let t = MockTransport([(#"{"id_token":"I2","refresh_token":"R2","user_id":"U","expires_in":"1800"}"#, 200)])
        let tokens = try await FirebaseAuth(transport: t).refresh(refreshToken: "a+b/c=")
        XCTAssertEqual(tokens.idToken, "I2"); XCTAssertEqual(tokens.uid, "U")
        let r = t.requests[0]
        XCTAssertTrue(r.url!.absoluteString.hasPrefix("https://securetoken.googleapis.com/v1/token?key="))
        XCTAssertEqual(String(decoding: r.httpBody!, as: UTF8.self), "grant_type=refresh_token&refresh_token=a%2Bb%2Fc%3D")
    }

    func testErrorMapping() async {
        let cases: [(String, TCError)] = [
            ("INVALID_LOGIN_CREDENTIALS", .invalidCredentials), ("EMAIL_NOT_FOUND", .invalidCredentials),
            ("USER_DISABLED", .userDisabled), ("TOO_MANY_ATTEMPTS_TRY_LATER : Access blocked", .tooManyAttempts),
            ("INVALID_EMAIL", .invalidEmail), ("TOKEN_EXPIRED", .sessionExpired),
        ]
        for (msg, expected) in cases {
            let body = #"{"error":{"code":400,"message":"\#(msg)"}}"#
            do {
                _ = try await FirebaseAuth(transport: MockTransport([(body, 400)])).signIn(email: "a", password: "b")
                XCTFail()
            } catch { XCTAssertEqual(error as? TCError, expected, msg) }
        }
    }
}

final class RSCTests: XCTestCase {
    func testObjectResult() {
        let text = "0:{\"a\":\"$@1\",\"f\":\"\",\"b\":\"X\"}\n1:{\"status\":\"stopped\",\"uptime\":0}\n"
        guard case .value(let v)? = RSC.parseResult(text) else { return XCTFail() }
        XCTAssertEqual((v as? [String: Any])?["status"] as? String, "stopped")
    }
    func testNullResult() {
        guard case .value(let v)? = RSC.parseResult("0:{\"a\":\"$@1\"}\n1:null\n") else { return XCTFail() }
        XCTAssertNil(v)
    }
    func testErrorLineAndMissing() {
        guard case .failure? = RSC.parseResult("0:{}\n1:E{\"digest\":\"123\"}\n") else { return XCTFail() }
        XCTAssertNil(RSC.parseResult("<html>Not found</html>"))
    }
    func testVmStatusParse() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"{"status":"running","uptime":120,"lock":null,"hasIp":true,"ip":"192.168.1.5","cpu":0.08,"mem":4294967296,"maxmem":19327352832,"netin":1,"netout":2,"isSunshineReady":true}"#.utf8)) as! [String: Any]
        let s = try VmStatus(json: json)
        XCTAssertTrue(s.isRunning && s.isSunshineReady && s.hasIP)
        XCTAssertNil(s.lock)
        XCTAssertEqual(s.uptime, 120)
    }
}

final class ResolverTests: XCTestCase {
    static let js = """
    r=(0,a.createServerReference)("704f8088419754f9101cf185d83c3f83282b29101e",a.callServer,void 0,a.findSourceMapURL,"getVmStatus")},77187:(e,t,s)=>{let r=(0,a.createServerReference)("7001161cd5d465a9e0e52102b38896c9ade0031dcd",a.callServer,void 0,a.findSourceMapURL,"shutdownVm")}
    """
    func testParseActions() {
        let m = ActionResolver.parseActions(inJS: Self.js)
        XCTAssertEqual(m["getVmStatus"], "704f8088419754f9101cf185d83c3f83282b29101e")
        XCTAssertEqual(m["shutdownVm"], "7001161cd5d465a9e0e52102b38896c9ade0031dcd")
        XCTAssertEqual(m.count, 2)
    }
    func testChunkURLs() {
        let html = #"<script src="/_next/static/chunks/app/dashboard/rig/page-87bf.js" async></script><script>self.__next_f.push(["\/_next\/static\/chunks\/1517-6382.js"])</script><script src="/_next/static/chunks/app/dashboard/rig/page-87bf.js"></script>"#
        XCTAssertEqual(ActionResolver.chunkURLs(inHTML: html), ["/_next/static/chunks/app/dashboard/rig/page-87bf.js", "/_next/static/chunks/1517-6382.js"])
    }
    func testRefreshOverridesFallbackIDs() async throws {
        let t = MockTransport([(#"<script src="/_next/static/chunks/a.js"></script>"#, 200),
                               (#"createServerReference)("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",a.callServer,void 0,a.findSourceMapURL,"startVm")"#, 200)])
        let r = ActionResolver(transport: t)
        let before = try await r.id(for: "startVm")
        XCTAssertEqual(before, "70f8bc378d09e94014feb9809a73f983a89e3e5ddb")
        try await r.refresh()
        let after = try await r.id(for: "startVm")
        XCTAssertEqual(after, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let other = try await r.id(for: "stopVm")
        XCTAssertEqual(other, TCConstants.fallbackActionIDs["stopVm"])
    }
}

final class RigAPITests: XCTestCase {
    func rsc(_ json: String) -> (String, Int) { ("0:{\"a\":\"$@1\"}\n1:\(json)\n", 200) }

    func testRequestShapes() async throws {
        let t = MockTransport([rsc("null"), rsc("{\"success\":true}"), rsc("{\"message\":\"ok\"}"), rsc("{}"), rsc("null")])
        let api = RigAPI(transport: t)
        try await api.sendPin(sunshineAddress: "h:35451", pin: "1234", idToken: "TK")
        try await api.startVm(node: "n", vmid: 754, idToken: "TK")
        try await api.shutdownVm(node: "n", vmid: 754, idToken: "TK")
        try await api.stopVm(node: "n", vmid: 754, idToken: "TK")
        try await api.unpairAllDevices(sunshineAddress: "h:35451", idToken: "TK")
        let bodies = t.requests.map { String(decoding: $0.httpBody!, as: UTF8.self) }
        XCTAssertEqual(bodies, [#"["h:35451","1234","TK"]"#, #"["n",754,"TK"]"#, #"["n",754,"TK"]"#, #"["n",754,"TK"]"#, #"["h:35451","TK"]"#])
        let ids = t.requests.map { $0.value(forHTTPHeaderField: "Next-Action")! }
        XCTAssertEqual(ids, ["sendPin", "startVm", "shutdownVm", "stopVm", "unpairAllDevices"].map { TCConstants.fallbackActionIDs[$0]! })
        let r = t.requests[0]
        XCTAssertEqual(r.url, TCConstants.rigPageURL)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), "text/x-component")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "text/plain;charset=UTF-8")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Referer"), "https://truecloud.in/dashboard/rig")
    }

    func testStatusParse() async throws {
        let t = MockTransport([rsc(#"{"status":"stopped","uptime":0,"lock":null,"hasIp":false,"ip":null,"cpu":0,"mem":0,"maxmem":19327352832,"isSunshineReady":false}"#)])
        let s = try await RigAPI(transport: t).vmStatus(node: "truecloud-2", vmid: 754, sunshineAddress: "h:35451")
        XCTAssertTrue(s.isStopped)
        XCTAssertEqual(String(decoding: t.requests[0].httpBody!, as: UTF8.self), #"["truecloud-2",754,"h:35451"]"#)
    }

    func testStaleIDTriggersReResolveAndRetry() async throws {
        let t = MockTransport([
            ("Not Found", 404),                                                     // stale id
            (#"<script src="/_next/static/chunks/p.js"></script>"#, 200),           // rig page
            (#"createServerReference)("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",a.callServer,void 0,a.findSourceMapURL,"startVm")"#, 200),
            rsc(#"{"success":true}"#),
        ])
        try await RigAPI(transport: t).startVm(node: "n", vmid: 1, idToken: "t")
        XCTAssertEqual(t.requests.count, 4)
        XCTAssertEqual(t.requests[3].value(forHTTPHeaderField: "Next-Action"), "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    }

    func testErrorsSurface() async {
        let api = RigAPI(transport: MockTransport([rsc(#"{"error":"Cooldown active"}"#)]))
        do { try await api.startVm(node: "n", vmid: 1, idToken: "t"); XCTFail() }
        catch { XCTAssertEqual(error as? TCError, .server("Cooldown active")) }
    }
}

/// Hits the real site. Read-only: fetches public HTML/JS and calls getVmStatus, never anything that changes state.
final class LiveReadOnlyTests: XCTestCase {
    func testResolverFindsAllActionsOnLiveSite() async throws {
        let resolver = ActionResolver()
        let found: [String: String]
        do { found = try await resolver.refresh() } catch { throw XCTSkip("offline: \(error)") }
        for name in TCConstants.fallbackActionIDs.keys {
            XCTAssertNotNil(found[name], "resolver did not find \(name)")
        }
        XCTAssertEqual(found.count >= 7, true)
        // Ids match the ones captured when this was written (they change on redeploys, so only warn).
        for (name, id) in TCConstants.fallbackActionIDs where found[name] != id {
            print("NOTE: live id for \(name) differs from fallback: \(found[name] ?? "nil")")
        }
    }

    func testLiveGetVmStatus() async throws {
        let api = RigAPI()
        let status: VmStatus
        do { status = try await api.vmStatus(node: "truecloud-2", vmid: 754, sunshineAddress: "moonlight-a2.truecloud.in:35451") }
        catch let e as TCError { if case .network = e { throw XCTSkip("offline") }; throw e }
        print("LIVE getVmStatus:", status)
        XCTAssertTrue(["running", "stopped"].contains(status.status))
    }
}

// MARK: - Account extras: activity log, payments, traffic, plan end date

final class AccountTests: XCTestCase {
    /// `vm_logs/<vmid>-<uid>` as Firestore returns it.
    static let activityDoc = """
    {"fields":{"vmid":{"integerValue":"754"},"userId":{"stringValue":"u1"},"entries":{"arrayValue":{"values":[
      {"mapValue":{"fields":{"id":{"stringValue":"a"},"type":{"stringValue":"start"},"status":{"stringValue":"Success: Start command sent"},
        "timestamp":{"timestampValue":"2026-11-04T17:42:58.100Z"},"clientIp":{"stringValue":"203.0.113.9"}}}},
      {"mapValue":{"fields":{"id":{"stringValue":"b"},"type":{"stringValue":"shutdown"},"status":{"stringValue":"Timed out waiting for stop status"},
        "timestamp":{"timestampValue":"2026-11-04T18:00:52Z"},"clientIp":{"stringValue":"203.0.113.9"}}}},
      {"mapValue":{"fields":{"id":{"stringValue":"c"},"type":{"stringValue":"system"},"status":{"stringValue":"Log initialized."},
        "timestamp":{"timestampValue":"2026-11-01T09:00:00Z"}}}},
      {"mapValue":{"fields":{"id":{"stringValue":"no-time"},"type":{"stringValue":"start"}}}}
    ]}}}}
    """

    /// `transactions/<uid>`: a failed upgrade and a successful first plan.
    static let paymentsDoc = """
    {"fields":{"userId":{"stringValue":"u1"},"records":{"arrayValue":{"values":[
      {"mapValue":{"fields":{"transactionId":{"stringValue":"t1"},"planName":{"stringValue":"Basic "},"amount":{"integerValue":"99900"},"currency":{"stringValue":"INR"},
        "status":{"stringValue":"success"},"isUpgrade":{"booleanValue":false},"createdAt":{"timestampValue":"2026-10-31T19:34:42.682Z"},
        "paymentId":{"stringValue":"p1"},"failureReason":{"nullValue":null},"plan":{"mapValue":{"fields":{"price":{"integerValue":"99900"}}}}}}},
      {"mapValue":{"fields":{"transactionId":{"stringValue":"t2"},"planName":{"stringValue":"Regular"},"amount":{"integerValue":"159920"},"currency":{"stringValue":"INR"},
        "status":{"stringValue":"failure"},"isUpgrade":{"booleanValue":true},"createdAt":{"timestampValue":"2026-10-31T21:12:00.697Z"},
        "failureReason":{"stringValue":"Payment declined"}}}},
      {"mapValue":{"fields":{"transactionId":{"stringValue":"t3"},"planName":{"stringValue":"Pro"},"status":{"stringValue":"refunded"}}}}
    ]}}}}
    """

    private func json(_ text: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }

    func testActivityLogParsesNewestFirstAndSkipsUndatedRows() {
        let log = ActivityEntry.parse(document: json(Self.activityDoc))
        XCTAssertEqual(log.map(\.id), ["b", "a", "c"])            // newest first; the row with no time is dropped
        XCTAssertEqual(log[0].title, "Shutdown")
        XCTAssertTrue(log[0].isFailure && !log[0].isSuccess)      // "Timed out waiting for stop status"
        XCTAssertTrue(log[1].isSuccess && !log[1].isFailure)
        XCTAssertFalse(log[2].isSuccess || log[2].isFailure)      // "Log initialized."
        XCTAssertEqual(log[1].timestamp.timeIntervalSince1970, 1_793_814_178.1, accuracy: 0.01)
    }

    func testPaymentsParseNewestFirstWithAmountsAsTheDashboardShowsThem() {
        let records = PaymentRecord.parse(document: json(Self.paymentsDoc))
        XCTAssertEqual(records.map(\.id), ["t2", "t1", "t3"])     // newest first; the undated record goes last
        XCTAssertEqual(records[0].amountText, "₹1599.20")
        XCTAssertEqual(records[0].status, .failure)
        XCTAssertEqual(records[0].typeText, "Upgrade")
        XCTAssertEqual(records[0].failureReason, "Payment declined")
        XCTAssertEqual(records[1].planName, "Basic")              // the stored name has a trailing space
        XCTAssertEqual(records[1].status, .success)
        XCTAssertEqual(records[1].typeText, "New Plan")
        XCTAssertNil(records[1].failureReason)
        XCTAssertEqual(records[2].amountText, "N/A")
        XCTAssertEqual(records[2].status, .other("refunded"))
    }

    func testActivityAndPaymentsAreFetchedFromTheRightDocuments() async throws {
        let t = MockTransport([(Self.activityDoc, 200), (Self.paymentsDoc, 200), ("{}", 404), ("{}", 403)])
        let client = FirestoreClient(transport: t)
        let log = try await client.activityLog(vmid: 754, uid: "u1", idToken: "TK")
        let paid = try await client.payments(uid: "u1", idToken: "TK")
        XCTAssertEqual(log.count, 3)
        XCTAssertEqual(paid.count, 3)
        XCTAssertTrue(t.requests[0].url!.absoluteString.hasSuffix("/documents/vm_logs/754-u1"))
        XCTAssertTrue(t.requests[1].url!.absoluteString.hasSuffix("/documents/transactions/u1"))
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer TK")
        // No document yet (a new account): empty, not an error
        let none = try await client.activityLog(vmid: 1, uid: "u2", idToken: "TK")
        XCTAssertEqual(none, [])
        do { _ = try await client.payments(uid: "u1", idToken: "TK"); XCTFail("403 should throw") }
        catch { XCTAssertEqual(error as? TCError, .sessionExpired) }
    }

    func testTrafficRatesMatchTheDashboardsFormula() {
        var meter = TrafficMeter()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        meter.record(netin: 10 * 1_048_576, netout: 1 * 1_048_576, at: t0)
        XCTAssertEqual(meter.rate, TrafficRate())                 // the first sample has nothing to compare with
        meter.record(netin: 30 * 1_048_576, netout: 3 * 1_048_576, at: t0.addingTimeInterval(4))
        XCTAssertEqual(meter.rate.downloadMBps, 5, accuracy: 1e-9)   // 20 MB over 4 s
        XCTAssertEqual(meter.rate.uploadMBps, 0.5, accuracy: 1e-9)
        // The PC restarted: counters went down. That is no traffic, never a negative speed.
        meter.record(netin: 1_000, netout: 500, at: t0.addingTimeInterval(8))
        XCTAssertEqual(meter.rate, TrafficRate())
        meter.reset()
        meter.record(netin: 5, netout: 5, at: t0.addingTimeInterval(20))
        XCTAssertEqual(meter.rate, TrafficRate())
        XCTAssertEqual(TrafficMeter.text(bytes: 1_572_864), "1.5 MB")
        XCTAssertEqual(TrafficMeter.text(bytes: -5), "Zero KB")
    }

    func testStatusCarriesTheNetworkCounters() throws {
        let s = try VmStatus(json: ["status": "running", "uptime": 60, "hasIp": true, "isSunshineReady": true,
                                    "netin": 2_097_152, "netout": 1_048_576, "cpu": 0.1, "mem": 1, "maxmem": 2])
        XCTAssertEqual(s.netin, 2_097_152)
        XCTAssertEqual(s.netout, 1_048_576)
        XCTAssertEqual(try VmStatus(json: ["status": "stopped"]).netin, 0)
    }

    func testPlanEndDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func profile(_ offset: TimeInterval?) -> RigProfile {
            RigProfile(uid: "u", node: "n", vmid: 1, moonlightHost: "h", expiration: offset.map { now.addingTimeInterval($0) })
        }
        XCTAssertEqual(profile(25.6 * 86_400).daysUntilExpiry(at: now), 25)
        XCTAssertFalse(profile(25.6 * 86_400).isExpiringSoon(at: now))
        XCTAssertTrue(profile(3.2 * 86_400).isExpiringSoon(at: now))
        XCTAssertTrue(profile(4.9 * 86_400).isExpiringSoon(at: now))
        XCTAssertFalse(profile(5.1 * 86_400).isExpiringSoon(at: now))
        XCTAssertTrue(profile(0.4 * 86_400).isExpiringSoon(at: now))      // less than a day left still counts
        XCTAssertFalse(profile(-3_600).isExpiringSoon(at: now))           // already ended: expired, not "soon"
        XCTAssertTrue(profile(-3_600).isExpired(at: now))
        XCTAssertNil(profile(nil).daysUntilExpiry(at: now))
        XCTAssertFalse(profile(nil).isExpiringSoon(at: now))
    }
}
