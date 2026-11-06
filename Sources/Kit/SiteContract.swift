import Foundation

/// What this app expects from TrueCloud's website, and a check that the live site still matches.
///
/// TrueCloud's dashboard is a Next.js app. Each Server Action id changes on every deploy, but its first byte
/// encodes the action's parameters: bits 1–6 mark which of the first six arguments it uses, bit 0 a rest
/// parameter (`0x70` = 3 arguments, `0x78` = 4, `0x60` = 2). So the app can tell, before calling anything,
/// whether an action it relies on was removed, renamed, or now takes different arguments, as `getVmStatus` did
/// on 2026-11-05 when it started requiring the user's ID token.
public enum SiteContract {
    /// Actions this app calls, with the number of parameters each declares (what its id encodes). An action can
    /// declare more than the dashboard passes: `getUserTransactions` declares 2 and is called with the token only.
    public static let actions: [String: Int] = [
        "getVmStatus": 4,        // node, vmid, sunshine address, ID token
        "startVm": 3,            // node, vmid, ID token
        "shutdownVm": 3,         // node, vmid, ID token
        "stopVm": 3,             // node, vmid, ID token
        "sendPin": 3,            // sunshine address, PIN, ID token
        "unpairAllDevices": 2,   // sunshine address, ID token
        "getVmLogs": 2,          // vmid, ID token (Activity)
        "getUserTransactions": 2, // ID token (+ one the dashboard doesn't pass) (Payments)
    ]

    /// The number of arguments an action id declares, or nil when the id isn't in Next.js's format.
    public static func arity(ofActionID id: String) -> (count: Int, rest: Bool)? {
        guard id.count >= 40, let byte = UInt8(id.prefix(2), radix: 16) else { return nil }
        let mask = (byte >> 1) & 0x3F
        return (mask.nonzeroBitCount, byte & 1 == 1)
    }

    /// Differences between the live action ids and what the app expects, in words. Empty when everything matches.
    public static func problems(in ids: [String: String], expected: [String: Int] = actions) -> [String] {
        expected.keys.sorted().compactMap { name in
            let want = expected[name]!
            guard let id = ids[name] else { return "\(name) is no longer on TrueCloud's site" }
            guard let have = arity(ofActionID: id) else { return "\(name) has an id this app can't read (\(id.prefix(8))…)" }
            if have.rest { return "\(name) now takes a variable number of values (expected \(want))" }
            if have.count != want { return "\(name) now takes \(have.count) value\(have.count == 1 ? "" : "s") (expected \(want))" }
            return nil
        }
    }

    /// Fields of the admin switches (GET /api/system-controls) the app reads.
    public static func systemControlsProblems(_ json: Any?) -> [String] {
        guard let dict = json as? [String: Any] else { return ["the admin switches (system-controls) aren't JSON any more"] }
        return dict["startButtonEnabled"] is Bool ? [] : ["the admin switches no longer say whether Start is allowed"]
    }
}
