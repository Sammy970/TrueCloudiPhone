import Foundation

// What TrueCloud keeps about an account besides the rig's profile: the activity log of the cloud PC's power events
// (the dashboard's "Activity Console") and the payment history (its "Payment History").
// Until 2026-11-05 both were Firestore documents (`vm_logs/<vmid>-<uid>`, `transactions/<uid>`) the user could read;
// since then Firestore refuses them and the dashboard loads them with the `getVmLogs` and `getUserTransactions`
// Server Actions, which this app now uses too. The Firestore parsers stay for tests and older data.

/// One power event of the cloud PC: a start, a shutdown, a force stop, and how it went.
public struct ActivityEntry: Equatable, Identifiable, Sendable {
    public var id: String
    /// "start", "shutdown", "system", …
    public var type: String
    /// What TrueCloud recorded, e.g. "Success: Start command sent" or "Timed out waiting for stop status".
    public var status: String
    public var timestamp: Date

    public init(id: String, type: String, status: String, timestamp: Date) {
        self.id = id; self.type = type; self.status = status; self.timestamp = timestamp
    }

    /// "Start", "Shutdown", …
    public var title: String { type.isEmpty ? "Event" : type.prefix(1).uppercased() + type.dropFirst() }
    public var isSuccess: Bool { status.lowercased().hasPrefix("success") }
    public var isFailure: Bool {
        let s = status.lowercased()
        return ["fail", "error", "timed out", "timeout", "denied", "refused"].contains { s.contains($0) }
    }

    /// Entries of a `vm_logs` document, newest first. The client IP TrueCloud stores with each entry is left out on purpose.
    public static func parse(document: [String: Any]) -> [ActivityEntry] {
        let fields = (document["fields"] as? [String: Any] ?? [:]).mapValues(FirestoreValue.init)
        let rows = fields["entries"]?.array ?? []
        let entries: [ActivityEntry] = rows.enumerated().compactMap { index, row in
            guard let map = row.map, let time = map["timestamp"]?.date else { return nil }
            return ActivityEntry(id: map["id"]?.string ?? "\(index)", type: map["type"]?.string ?? "",
                                 status: map["status"]?.string ?? "", timestamp: time)
        }
        return entries.sorted { $0.timestamp > $1.timestamp }
    }
}

extension ActivityEntry {
    /// Entries of a `getVmLogs` answer (`{"success": true, "logs": [...]}`), newest first. Client IPs are dropped.
    public static func parse(actionResult value: Any?) throws -> [ActivityEntry] {
        let rows = try ActionJSON.list(value, key: "logs")
        let entries: [ActivityEntry] = rows.enumerated().compactMap { index, row in
            guard let time = ActionJSON.date(row["timestamp"]) else { return nil }
            return ActivityEntry(id: row["id"] as? String ?? "\(index)", type: row["type"] as? String ?? "",
                                 status: row["status"] as? String ?? "", timestamp: time)
        }
        return entries.sorted { $0.timestamp > $1.timestamp }
    }
}

/// One payment on the account.
public struct PaymentRecord: Equatable, Identifiable, Sendable {
    public enum Status: Equatable, Sendable { case success, failure, pending, other(String) }

    public var id: String
    public var planName: String
    /// In the currency's smallest unit (paise): 99900 is ₹999.00. The dashboard divides by 100.
    public var amount: Int?
    public var currency: String
    public var status: Status
    public var isUpgrade: Bool
    public var createdAt: Date?
    public var failureReason: String?

    public init(id: String, planName: String, amount: Int?, currency: String = "INR", status: Status,
                isUpgrade: Bool = false, createdAt: Date?, failureReason: String? = nil) {
        self.id = id; self.planName = planName; self.amount = amount; self.currency = currency; self.status = status
        self.isUpgrade = isUpgrade; self.createdAt = createdAt; self.failureReason = failureReason
    }

    /// "₹999.00", like the dashboard's table; "N/A" when the record has no amount.
    public var amountText: String {
        guard let amount else { return "N/A" }
        let symbol = currency.uppercased() == "INR" || currency.isEmpty ? "₹" : "\(currency.uppercased()) "
        return symbol + String(format: "%.2f", Double(amount) / 100)
    }

    public var typeText: String { isUpgrade ? "Upgrade" : "New Plan" }

    /// Records of a `transactions/<uid>` document, newest first.
    public static func parse(document: [String: Any]) -> [PaymentRecord] {
        let fields = (document["fields"] as? [String: Any] ?? [:]).mapValues(FirestoreValue.init)
        let rows = fields["records"]?.array ?? []
        let records: [PaymentRecord] = rows.enumerated().compactMap { index, row in
            guard let map = row.map else { return nil }
            let status: Status = switch map["status"]?.string?.lowercased() {
            case "success": .success
            case "failure": .failure
            case "pending": .pending
            case let other?: .other(other)
            case nil: .other("unknown")
            }
            return PaymentRecord(
                id: map["transactionId"]?.string ?? "\(index)",
                planName: (map["planName"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                amount: map["amount"]?.number.map { Int($0) },
                currency: map["currency"]?.string ?? "INR",
                status: status,
                isUpgrade: map["isUpgrade"]?.bool ?? false,
                createdAt: map["createdAt"]?.date,
                failureReason: map["failureReason"]?.string)
        }
        return records.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}

extension PaymentRecord {
    /// Records of a `getUserTransactions` answer (`{"success": true, "transactions": [...]}`), newest first.
    public static func parse(actionResult value: Any?) throws -> [PaymentRecord] {
        let rows = try ActionJSON.list(value, key: "transactions")
        let records: [PaymentRecord] = rows.enumerated().map { index, row in
            let status: Status = switch (row["status"] as? String)?.lowercased() {
            case "success": .success
            case "failure": .failure
            case "pending": .pending
            case let other?: .other(other)
            case nil: .other("unknown")
            }
            return PaymentRecord(
                id: row["transactionId"] as? String ?? "\(index)",
                planName: (row["planName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                amount: (row["amount"] as? NSNumber)?.intValue,
                currency: row["currency"] as? String ?? "INR",
                status: status,
                isUpgrade: row["isUpgrade"] as? Bool ?? false,
                createdAt: ActionJSON.date(row["createdAt"]),
                failureReason: row["failureReason"] as? String)
        }
        return records.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}

/// Helpers for Server Action answers.
enum ActionJSON {
    /// The array under `key` of a `{"success": true, key: [...]}` answer.
    static func list(_ value: Any?, key: String) throws -> [[String: Any]] {
        guard let dict = value as? [String: Any] else { throw TCError.unexpectedResponse }
        if dict["success"] as? Bool == false {
            throw TCError.server((dict["message"] as? String) ?? (dict["error"] as? String) ?? "TrueCloud refused the request.")
        }
        if dict[key] == nil || dict[key] is NSNull { return [] }
        guard let rows = dict[key] as? [[String: Any]] else { throw TCError.unexpectedResponse }
        return rows
    }

    /// React Server Components send dates as "$D<ISO 8601>".
    static func date(_ value: Any?) -> Date? {
        guard var text = value as? String else {
            if let ms = (value as? NSNumber)?.doubleValue { return Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms) }
            return nil
        }
        if text.hasPrefix("$D") { text.removeFirst(2) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

extension FirestoreClient {
    /// The cloud PC's power-event log. Empty for an account that has none yet (no document).
    public func activityLog(vmid: Int, uid: String, idToken: String) async throws -> [ActivityEntry] {
        guard let document = try await document("vm_logs/\(vmid)-\(uid)", idToken: idToken) else { return [] }
        return ActivityEntry.parse(document: document)
    }

    /// The account's payments. Empty for an account that has never paid (no document).
    public func payments(uid: String, idToken: String) async throws -> [PaymentRecord] {
        guard let document = try await document("transactions/\(uid)", idToken: idToken) else { return [] }
        return PaymentRecord.parse(document: document)
    }

    /// A Firestore document as JSON, nil when it doesn't exist.
    func document(_ path: String, idToken: String) async throws -> [String: Any]? {
        var request = URLRequest(url: URL(string:
            "https://firestore.googleapis.com/v1/projects/\(TCConstants.firebaseProject)/databases/(default)/documents/\(path)")!)
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, status) = try await transport.send(request)
        switch status {
        case 200..<300: break
        case 401, 403: throw TCError.sessionExpired
        case 404: return nil
        default: throw TCError.http(status)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TCError.unexpectedResponse }
        return json
    }
}
