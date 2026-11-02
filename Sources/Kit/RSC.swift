import Foundation

/// Reads the result of a Next.js Server Action from its `text/x-component` (RSC) response:
/// line 0 is `0:{"a":"$@1",…}` and line 1 is `1:<json result>`.
public enum RSC {
    public enum Result {
        case value(Any?)   // decoded JSON (nil for `null`)
        case failure(String)
    }

    /// Returns nil when there is no `1:` line (e.g. an HTML error page or a stale action id).
    public static func parseResult(_ text: String) -> Result? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("1:") {
            let payload = line.dropFirst(2)
            // `1:E{"digest":"…"}` is how React serialises a thrown server error.
            if payload.hasPrefix("E") {
                let body = payload.dropFirst()
                let digest = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
                let message = (digest?["message"] as? String) ?? "TrueCloud reported a server error."
                return .failure(message)
            }
            guard let value = try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed]) else {
                return nil
            }
            return .value(value is NSNull ? nil : value)
        }
        return nil
    }
}
