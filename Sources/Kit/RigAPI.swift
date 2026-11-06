import Foundation

/// What `getVmStatus` reports.
public struct VmStatus: Equatable, Sendable {
    public var status: String          // "running", "stopped", …
    public var uptime: Int             // seconds
    public var lock: String?           // "clone" while a new rig is being built
    public var hasIP: Bool
    public var ip: String?
    public var cpu: Double             // 0...1
    public var mem: Double             // bytes
    public var maxmem: Double
    /// Bytes the cloud PC has received and sent since it started (running counters).
    public var netin: Double
    public var netout: Double
    public var isSunshineReady: Bool

    public var isRunning: Bool { status == "running" }
    public var isStopped: Bool { status == "stopped" }

    public init(status: String, uptime: Int = 0, lock: String? = nil, hasIP: Bool = false, ip: String? = nil,
                cpu: Double = 0, mem: Double = 0, maxmem: Double = 0, netin: Double = 0, netout: Double = 0,
                isSunshineReady: Bool = false) {
        self.status = status; self.uptime = uptime; self.lock = lock; self.hasIP = hasIP; self.ip = ip
        self.cpu = cpu; self.mem = mem; self.maxmem = maxmem; self.netin = netin; self.netout = netout
        self.isSunshineReady = isSunshineReady
    }

    public init(json: [String: Any]) throws {
        guard let status = json["status"] as? String else {
            if let error = json["error"] as? String { throw TCError.server(error) }
            throw TCError.unexpectedResponse
        }
        func num(_ k: String) -> Double { (json[k] as? NSNumber)?.doubleValue ?? 0 }
        self.init(status: status, uptime: Int(num("uptime")), lock: json["lock"] as? String,
                  hasIP: json["hasIp"] as? Bool ?? false, ip: json["ip"] as? String,
                  cpu: num("cpu"), mem: num("mem"), maxmem: num("maxmem"), netin: num("netin"), netout: num("netout"),
                  isSunshineReady: json["isSunshineReady"] as? Bool ?? false)
    }
}

/// The switches TrueCloud's administrators flip (GET /api/system-controls, public). The dashboard greys out Start
/// while `startButtonEnabled` is false and shows the reason.
public struct SystemControls: Equatable, Sendable {
    public var startEnabled: Bool
    public var startDisabledReason: String?

    public init(startEnabled: Bool = true, startDisabledReason: String? = nil) {
        self.startEnabled = startEnabled
        self.startDisabledReason = startDisabledReason
    }

    public init?(json: Any?) {
        guard let dict = json as? [String: Any] else { return nil }
        self.init(startEnabled: dict["startButtonEnabled"] as? Bool ?? true,
                  startDisabledReason: dict["startButtonDisabledReason"] as? String)
    }
}

/// TrueCloud's dashboard Server Actions (POST /dashboard/rig).
public struct RigAPI: Sendable {
    let transport: HTTPTransport
    public let resolver: ActionResolver

    public init(transport: HTTPTransport = URLSessionTransport(), resolver: ActionResolver? = nil) {
        self.transport = transport
        self.resolver = resolver ?? ActionResolver(transport: transport)
    }

    /// Read-only. Needs the account's ID token since TrueCloud's 2026-11-05 update.
    public func vmStatus(node: String, vmid: Int, sunshineAddress: String, idToken: String) async throws -> VmStatus {
        let value = try await call("getVmStatus", args: [node, vmid, sunshineAddress, idToken])
        guard let json = value as? [String: Any] else { throw TCError.unexpectedResponse }
        return try VmStatus(json: json)
    }

    /// Powers the rig on. Uses plan hours.
    public func startVm(node: String, vmid: Int, idToken: String) async throws {
        _ = try await call("startVm", args: [node, vmid, idToken])
    }

    /// Graceful Windows shutdown.
    public func shutdownVm(node: String, vmid: Int, idToken: String) async throws {
        _ = try await call("shutdownVm", args: [node, vmid, idToken])
    }

    /// Hard power-off.
    public func stopVm(node: String, vmid: Int, idToken: String) async throws {
        _ = try await call("stopVm", args: [node, vmid, idToken])
    }

    /// Whether administrators have paused starting cloud PCs. nil when it can't be read: the server enforces the
    /// pause anyway, so a failed read never blocks a start.
    public func systemControls() async -> SystemControls? {
        var request = URLRequest(url: TCConstants.siteBase.appendingPathComponent("api/system-controls"))
        request.timeoutInterval = 15
        guard let (data, status) = try? await transport.send(request) else { return nil }
        if TCError.blockedClient(status: status, body: data) != nil { return nil }
        guard (200..<300).contains(status) else { return nil }
        return SystemControls(json: try? JSONSerialization.jsonObject(with: data))
    }

    /// The raw admin-switch JSON, for the compatibility check.
    public func systemControlsJSON() async throws -> Any? {
        var request = URLRequest(url: TCConstants.siteBase.appendingPathComponent("api/system-controls"))
        request.timeoutInterval = 15
        let (data, status) = try await transport.send(request)
        if let blocked = TCError.blockedClient(status: status, body: data) { throw blocked }
        guard (200..<300).contains(status) else { throw TCError.http(status) }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The cloud PC's power events (the dashboard's Activity Console), newest first.
    public func vmLogs(vmid: Int, idToken: String) async throws -> [ActivityEntry] {
        try ActivityEntry.parse(actionResult: try await call("getVmLogs", args: [vmid, idToken]))
    }

    /// The account's payments (the dashboard's Payment History), newest first. Lives on the history page.
    public func transactions(idToken: String) async throws -> [PaymentRecord] {
        try PaymentRecord.parse(actionResult: try await call("getUserTransactions", args: [idToken],
                                                             page: TCConstants.historyPageURL))
    }

    /// Gives Sunshine the PIN that Moonlight's pair request is showing.
    public func sendPin(sunshineAddress: String, pin: String, idToken: String) async throws {
        _ = try await call("sendPin", args: [sunshineAddress, pin, idToken])
    }

    /// Forgets every paired Moonlight client on the rig.
    public func unpairAllDevices(sunshineAddress: String, idToken: String) async throws {
        _ = try await call("unpairAllDevices", args: [sunshineAddress, idToken])
    }

    // MARK: Transport

    /// Calls a Server Action. If the id is stale (404, or an answer without an RSC result) the ids are
    /// re-read from the site and the call retried once.
    func call(_ action: String, args: [Any], page: URL = TCConstants.rigPageURL) async throws -> Any? {
        var refreshed = false
        while true {
            let id = try await resolver.id(for: action)
            let request = try Self.request(actionID: id, args: args, page: page)
            let (data, status) = try await transport.send(request)
            let text = String(decoding: data, as: UTF8.self)
            if let blocked = TCError.blockedClient(status: status, body: data) { throw blocked }

            let stale = status == 404 || (status < 500 && RSC.parseResult(text) == nil && status != 401)
            if (stale || status == 400) && !refreshed {
                refreshed = true
                if (try? await resolver.refresh()) != nil { continue }
            }
            if status == 401 || status == 403 { throw TCError.sessionExpired }
            guard let result = RSC.parseResult(text) else {
                throw status >= 400 ? TCError.http(status) : TCError.unexpectedResponse
            }
            switch result {
            case .failure(let message):
                throw TCError.server(message)
            case .value(let value):
                // Actions report refusals as {"error": "…"} (e.g. cooldowns, no time left).
                if let dict = value as? [String: Any], dict["status"] == nil, let message = dict["error"] as? String {
                    throw TCError.server(message)
                }
                if let dict = value as? [String: Any], dict["success"] as? Bool == false {
                    throw TCError.server((dict["message"] as? String) ?? "TrueCloud refused the request.")
                }
                return value
            }
        }
    }

    static func request(actionID: String, args: [Any], page: URL = TCConstants.rigPageURL) throws -> URLRequest {
        var request = URLRequest(url: page)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("text/x-component", forHTTPHeaderField: "Accept")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(actionID, forHTTPHeaderField: "Next-Action")
        request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://truecloud.in", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: args)
        return request
    }
}
