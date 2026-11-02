import Foundation

/// A user's cloud PC, from the Firestore document `users/<uid>`.
public struct RigProfile: Equatable, Sendable {
    public var uid: String
    public var displayName: String
    public var photoURL: String?
    public var node: String
    public var vmid: Int
    public var moonlightHost: String
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

    public init(uid: String, displayName: String = "", photoURL: String? = nil, node: String, vmid: Int,
                moonlightHost: String, sunshineAddress: String? = nil, currentPlan: String = "",
                hoursRemaining: Double = 0, planHours: Double = 0, dailyLimitHours: Double = 0,
                nightPlan: Bool = false, subscription: Bool = true, autoRenew: Bool = false,
                provisioningStatus: String = "ready", hasPairedBefore: Bool = false, expiration: Date? = nil) {
        self.uid = uid
        self.displayName = displayName
        self.photoURL = photoURL
        self.node = node
        self.vmid = vmid
        self.moonlightHost = moonlightHost
        self.sunshineAddress = sunshineAddress ?? "\(moonlightHost):\(TCConstants.sunshinePort)"
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

        let sunshine: String
        switch fields["sunshine_port"] {
        case .string(let s) where s.contains(":"): sunshine = s
        case let v? where v.number != nil: sunshine = "\(host):\(Int(v.number!))"
        default: sunshine = "\(host):\(TCConstants.sunshinePort)"
        }
        return RigProfile(
            uid: uid,
            displayName: string("displayName") ?? "",
            photoURL: string("photoURL"),
            node: node, vmid: vmid, moonlightHost: host, sunshineAddress: sunshine,
            currentPlan: string("currentplan") ?? "",
            hoursRemaining: hours(fields["time_remain"]),
            planHours: hours(fields["time_plan"]),
            dailyLimitHours: hours(fields["daily_limit"]),
            nightPlan: fields["night_plan"]?.bool ?? false,
            subscription: fields["subscription"]?.bool ?? false,
            autoRenew: fields["auto_renew"]?.bool ?? false,
            provisioningStatus: string("provisioningStatus") ?? "",
            hasPairedBefore: fields["hasPairedBefore"]?.bool ?? false,
            expiration: fields["expiration"]?.date
        )
    }

    /// Stored as milliseconds (14220000 = 3.95 h); the dashboard prints hours. Anything above 1000
    /// cannot sensibly be hours of plan time per day, so it is read as milliseconds.
    static func hours(_ value: FirestoreValue?) -> Double {
        guard let n = value?.number else { return 0 }
        return abs(n) > 1000 ? n / 3_600_000 : n
    }
}

/// A typed Firestore value. Numbers may arrive as integerValue, doubleValue or a numeric stringValue.
enum FirestoreValue: Equatable {
    case string(String), integer(Double), double(Double), bool(Bool), timestamp(String), null, other

    init(_ raw: Any) {
        guard let dict = raw as? [String: Any] else { self = .other; return }
        if let s = dict["stringValue"] as? String { self = .string(s) }
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
}
