import Foundation

/// Fixed facts about TrueCloud's public web app (observed from truecloud.in).
public enum TCConstants {
    /// Firebase web API key of the TrueCloud web app. Public by design (it ships in their JS bundle).
    public static let firebaseAPIKey = "AIzaSyDRwLOSZjz-j-yUsy28MX4WgU0R3izOlLE"
    public static let firebaseProject = "truecloud-866c9"
    public static let siteBase = URL(string: "https://truecloud.in")!
    public static let rigPageURL = URL(string: "https://truecloud.in/dashboard/rig")!
    /// The payment history page; `getUserTransactions` is only referenced there.
    public static let historyPageURL = URL(string: "https://truecloud.in/dashboard/history")!

    /// Defaults only, for a profile that doesn't carry its own `moonlight_port` / `sunshine_port`: every account has
    /// its own ports, so streams use `RigProfile.moonlightPort`. Sunshine's port is one above Moonlight's.
    public static let streamPort = 35450
    public static let sunshinePort = 35451

    /// Server Action ids seen on 2026-11-05. Used only until `ActionResolver` reads the live ones.
    public static let fallbackActionIDs: [String: String] = [
        "getVmStatus": "78efbf422aec3b72c82274c29cf0965c83bd7a9ac9",
        "startVm": "70c9f28420112ef12c768e0dcca54442ab73d0c815",
        "shutdownVm": "70c78897d892e900b90b91dcdeb24813e7edc973d6",
        "stopVm": "70fa509542f9f3deedf5483e3f7c41776d58dc9ef4",
        "sendPin": "70284d958182350cb9818063e24a0f207fbfdf6cee",
        "unpairAllDevices": "60c685a64b3f552dfac8d488f03a8ca31ce1ebf6aa",
        "resetVm": "782ff6802708bc1b775faadee0e2b9e8e5ad652e6c",
        "getVmLogs": "60fb41cda1f5890189248b316490c6a94337364229",
        "getUserTransactions": "60443fbb6684e05ab14f31ebbc219ac6e873bb4f87",
    ]
}

/// Errors with messages fit to show to a person.
public enum TCError: LocalizedError, Equatable {
    case invalidCredentials
    case userDisabled
    case tooManyAttempts
    case invalidEmail
    case sessionExpired
    case network(String)
    case http(Int)
    case server(String)
    case profileMissing
    case unexpectedResponse
    case actionsUnavailable
    /// truecloud.in refused the request because it isn't from a browser (the server's own words).
    case clientBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Incorrect email or password. If you signed up with Google, use \"Forgot password\" once to set a password."
        case .userDisabled: "This account has been disabled. Contact TrueCloud support."
        case .tooManyAttempts: "Too many attempts. Wait a few minutes, or reset your password."
        case .invalidEmail: "That email address doesn't look right."
        case .sessionExpired: "Your session expired. Please sign in again."
        case .network(let m): "Couldn't reach TrueCloud (\(m)). Check your internet connection."
        case .http(let code): "TrueCloud answered with an error (\(code))."
        case .server(let m): m
        case .profileMissing: "No cloud PC was found for this account. Set one up at truecloud.in first."
        case .unexpectedResponse: "TrueCloud sent a response this app doesn't understand. It may have changed its site."
        case .actionsUnavailable: "Couldn't find TrueCloud's controls on its website. It may have changed; this app needs an update."
        case .clientBlocked(let m):
            "TrueCloud's website is refusing this app (\"\(m)\"). Start and stop your cloud PC at truecloud.in for now."
        }
    }

    /// The website's answer when it blocks apps that aren't a browser: 403 with a plain-text reason.
    /// Returns nil for any other refusal, so a real expired session still reads as one.
    public static func blockedClient(status: Int, body: Data) -> TCError? {
        guard status == 403 else { return nil }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Seen so far: "Forbidden: Third-party client application blocked." (pages) and
        // "Forbidden: Only official browser clients may invoke actions." (Server Actions).
        // and since 2026-11-06 "Forbidden: Browser web session required. External third-party apps are not permitted."
        let wording = text.localizedCaseInsensitiveContains("client") || text.localizedCaseInsensitiveContains("third-party apps")
        guard wording,
              ["blocked", "official browser", "third-party", "web session"].contains(where: { text.localizedCaseInsensitiveContains($0) })
        else { return nil }
        return .clientBlocked(text)
    }
}

// MARK: - HTTP

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            throw TCError.network(error.localizedDescription)
        }
    }
}
