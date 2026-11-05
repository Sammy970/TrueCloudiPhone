import Foundation

// What TrueCloud keeps about an account besides the rig's profile: the activity log of the cloud PC's power events
// (`vm_logs/<vmid>-<uid>`, shown by the dashboard as its "Activity Console") and the payment history
// (`transactions/<uid>`, the dashboard's "Payment History"). Both are Firestore documents the signed-in user can read.

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
