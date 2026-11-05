import Foundation

/// A user's cloud PC, from the Firestore document `users/<uid>`.
public struct RigProfile: Equatable, Sendable {
    public var uid: String
    public var displayName: String
    public var photoURL: String?
    public var node: String
    public var vmid: Int
    public var moonlightHost: String
    /// The Moonlight port of this account's rig (`moonlight_port`). It differs per account, so a stream address
    /// is always `<gateway host>:<this port>`, the same "Server A2 / A4 Endpoint" the dashboard shows.
    public var moonlightPort: Int
    /// "host:35451" as stored by TrueCloud (or built from the host); used for status, PIN and unpair calls.
    public var sunshineAddress: String
    public var currentPlan: String
    /// Hours. TrueCloud's database stores milliseconds; values are normalised on parse.
    public var hoursRemaining: Double
    public var planHours: Double
    public var dailyLimitHours: Double
    public var nightPlan: Bool
    public var subscription: Bool
    public var autoRenew: Bool
    public var provisioningStatus: String
    public var hasPairedBefore: Bool
    public var expiration: Date?

    /// The dashboard shows "Unlimited" for plans above 360 hours.
    public var isUnlimited: Bool { planHours > 360 }
    public var planName: String {
        let t = currentPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "No plan" : t
    }

    /// Minutes of plan time left, nil when unlimited.
    public var minutesLeft: Int? { isUnlimited ? nil : max(0, Int((hoursRemaining * 60).rounded())) }
    /// The site requires at least 3 minutes (0.05 h) to start.
    public var hasEnoughTimeToStart: Bool { isUnlimited || hoursRemaining >= 0.05 }
    /// The plan's end date has passed: the dashboard disables every button then.
    public func isExpired(at now: Date = .now) -> Bool { expiration.map { $0 < now } ?? false }
    /// Whole days until the plan ends (nil without an end date, negative once it has passed).
    public func daysUntilExpiry(at now: Date = .now) -> Int? {
        expiration.map { Int(($0.timeIntervalSince(now) / 86_400).rounded(.down)) }
    }
    /// The dashboard warns ("Subscription Expiring Soon") when fewer than 5 days are left.
    public func isExpiringSoon(at now: Date = .now) -> Bool {
        guard let days = daysUntilExpiry(at: now) else { return false }
        return days >= 0 && days < 5 && !isExpired(at: now)
    }
    /// While TrueCloud is still building the rig the dashboard shows a "Provisioning" card and no controls.
    public var isProvisioned: Bool { provisioningStatus == "ready" }

    public init(uid: String, displayName: String = "", photoURL: String? = nil, node: String, vmid: Int,
                moonlightHost: String, moonlightPort: Int? = nil, sunshineAddress: String? = nil, currentPlan: String = "",
                hoursRemaining: Double = 0, planHours: Double = 0, dailyLimitHours: Double = 0,
                nightPlan: Bool = false, subscription: Bool = true, autoRenew: Bool = false,
                provisioningStatus: String = "ready", hasPairedBefore: Bool = false, expiration: Date? = nil) {
        self.uid = uid
        self.displayName = displayName
        self.photoURL = photoURL
        self.node = node
        self.vmid = vmid
        self.moonlightHost = moonlightHost
        self.moonlightPort = moonlightPort ?? TCConstants.streamPort
        // Sunshine's port sits right after Moonlight's on TrueCloud's gateways (35450 and 35451).
        self.sunshineAddress = sunshineAddress ?? "\(moonlightHost):\(moonlightPort.map { $0 + 1 } ?? TCConstants.sunshinePort)"
        self.currentPlan = currentPlan
        self.hoursRemaining = hoursRemaining
        self.planHours = planHours
        self.dailyLimitHours = dailyLimitHours
        self.nightPlan = nightPlan
        self.subscription = subscription
        self.autoRenew = autoRenew
        self.provisioningStatus = provisioningStatus
        self.hasPairedBefore = hasPairedBefore
        self.expiration = expiration
    }

    /// Parses a Firestore REST document (`{"fields": {"node": {"stringValue": "…"}, …}}`).
    public static func parse(document: [String: Any], uid: String) throws -> RigProfile {
        let fields = (document["fields"] as? [String: Any] ?? [:]).mapValues(FirestoreValue.init)
        func string(_ key: String) -> String? { fields[key]?.string }
        guard let node = string("node"), let vmid = fields["vmid"]?.number.map(Int.init),
              let host = string("moonlight_ip") else { throw TCError.profileMissing }

        // Every account has its own ports; only fall back to the defaults when the profile doesn't say.
        let moonlightPort = fields["moonlight_port"]?.number.map(Int.init)
        let sunshine: String
        switch fields["sunshine_port"] {
        case .string(let s) where s.contains(":"): sunshine = s
        case let v? where v.number != nil: sunshine = "\(host):\(Int(v.number!))"
        default: sunshine = "\(host):\(moonlightPort.map { $0 + 1 } ?? TCConstants.sunshinePort)"
        }
        return RigProfile(
            uid: uid,
            displayName: string("displayName") ?? "",
            photoURL: string("photoURL"),
            node: node, vmid: vmid, moonlightHost: host, moonlightPort: moonlightPort, sunshineAddress: sunshine,
            currentPlan: string("currentplan") ?? "",
            hoursRemaining: hours(fields["time_remain"]),
            planHours: hours(fields["time_plan"]),
            dailyLimitHours: hours(fields["daily_limit"]),
            nightPlan: fields["night_plan"]?.bool ?? false,
            subscription: fields["subscription"]?.bool ?? false,
            autoRenew: fields["auto_renew"]?.bool ?? false,
            provisioningStatus: string("provisioningStatus") ?? "ready",  // the dashboard's default too
            hasPairedBefore: fields["hasPairedBefore"]?.bool ?? false,
            expiration: fields["expiration"]?.date
        )
    }

    /// Stored as milliseconds (14220000 = 3.95 h) and always divided by 3,600,000, as the dashboard does. (A guess
    /// that small numbers were already hours would let 500 ms left pass as 500 hours.)
    static func hours(_ value: FirestoreValue?) -> Double {
        guard let n = value?.number else { return 0 }
        return n / 3_600_000
    }
}

/// A typed Firestore value. Numbers may arrive as integerValue, doubleValue or a numeric stringValue.
indirect enum FirestoreValue: Equatable {
    case string(String), integer(Double), double(Double), bool(Bool), timestamp(String), null, other
    case array([FirestoreValue]), map([String: FirestoreValue])

    init(_ raw: Any) {
        guard let dict = raw as? [String: Any] else { self = .other; return }
        if let a = dict["arrayValue"] as? [String: Any] {
            self = .array((a["values"] as? [Any] ?? []).map(FirestoreValue.init))
        } else if let m = dict["mapValue"] as? [String: Any] {
            self = .map((m["fields"] as? [String: Any] ?? [:]).mapValues(FirestoreValue.init))
        } else if let s = dict["stringValue"] as? String { self = .string(s) }
        else if let i = dict["integerValue"] { self = .integer(Double("\(i)") ?? 0) }
        else if let d = dict["doubleValue"] { self = .double(Double("\(d)") ?? 0) }
        else if let b = dict["booleanValue"] as? Bool { self = .bool(b) }
        else if let t = dict["timestampValue"] as? String { self = .timestamp(t) }
        else if dict["nullValue"] != nil { self = .null }
        else { self = .other }
    }

    var string: String? {
        switch self {
        case .string(let s): s
        case .integer(let n), .double(let n): n == n.rounded() ? String(Int(n)) : String(n)
        default: nil
        }
    }

    var number: Double? {
        switch self {
        case .integer(let n), .double(let n): n
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .string(let s): ["true", "yes", "1"].contains(s.lowercased())
        default: nil
        }
    }

    var array: [FirestoreValue]? {
        if case .array(let values) = self { values } else { nil }
    }

    var map: [String: FirestoreValue]? {
        if case .map(let fields) = self { fields } else { nil }
    }

    var date: Date? {
        guard case .timestamp(let s) = self else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

public struct FirestoreClient: Sendable {
    let transport: HTTPTransport
    public init(transport: HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func profile(uid: String, idToken: String) async throws -> RigProfile {
        var request = URLRequest(url: URL(string:
            "https://firestore.googleapis.com/v1/projects/\(TCConstants.firebaseProject)/databases/(default)/documents/users/\(uid)")!)
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, status) = try await transport.send(request)
        switch status {
        case 200..<300: break
        case 401, 403: throw TCError.sessionExpired
        case 404: throw TCError.profileMissing
        default: throw TCError.http(status)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TCError.unexpectedResponse }
        return try RigProfile.parse(document: json, uid: uid)
    }

    /// The write the dashboard makes after a PIN is accepted: it sets `hasPairedBefore` on the user's own document
    /// (its home page shows the "get connected" guide until then). Only that field is touched.
    public func markPairedBefore(uid: String, idToken: String) async throws {
        var request = URLRequest(url: URL(string:
            "https://firestore.googleapis.com/v1/projects/\(TCConstants.firebaseProject)/databases/(default)/documents/users/\(uid)?updateMask.fieldPaths=hasPairedBefore")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"fields":{"hasPairedBefore":{"booleanValue":true}}}"#.utf8)
        request.timeoutInterval = 30
        let (_, status) = try await transport.send(request)
        switch status {
        case 200..<300: break
        case 401, 403: throw TCError.sessionExpired
        default: throw TCError.http(status)
        }
    }
}
