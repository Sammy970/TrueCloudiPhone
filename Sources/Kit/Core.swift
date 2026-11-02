import Foundation

/// Fixed facts about TrueCloud's public web app (observed from truecloud.in).
public enum TCConstants {
    /// Firebase web API key of the TrueCloud web app. Public by design (it ships in their JS bundle).
    public static let firebaseAPIKey = "AIzaSyDRwLOSZjz-j-yUsy28MX4WgU0R3izOlLE"
    public static let firebaseProject = "truecloud-866c9"
    public static let siteBase = URL(string: "https://truecloud.in")!
    public static let rigPageURL = URL(string: "https://truecloud.in/dashboard/rig")!

    /// Moonlight streaming port; Sunshine's pairing/config port is one above it.
    public static let streamPort = 35450
    public static let sunshinePort = 35451

    /// Server Action ids seen on 2026-11-02. Used only until `ActionResolver` reads the live ones.
    public static let fallbackActionIDs: [String: String] = [
        "getVmStatus": "704f8088419754f9101cf185d83c3f83282b29101e",
        "startVm": "70f8bc378d09e94014feb9809a73f983a89e3e5ddb",
        "shutdownVm": "7001161cd5d465a9e0e52102b38896c9ade0031dcd",
        "stopVm": "70c1a77813442e779b591e265b452af97dabd6c5d0",
        "sendPin": "7082f669df29c7fe4b74f7ceb46bb043da33d04c59",
        "unpairAllDevices": "60bd4878c49a51b0f1167642e6d7af594888a69120",
        "resetVm": "788af732f1ea0ff2585a96322b9439d3876be63e93",
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
        }
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
