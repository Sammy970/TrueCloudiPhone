import Foundation

public struct AuthTokens: Equatable, Sendable {
    public var idToken: String
    public var refreshToken: String
    public var uid: String
    public var expiresAt: Date

    public init(idToken: String, refreshToken: String, uid: String, expiresAt: Date) {
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.uid = uid
        self.expiresAt = expiresAt
    }
}

/// Firebase Auth over its public REST API (email and password only).
public struct FirebaseAuth: Sendable {
    let transport: HTTPTransport
    let apiKey: String
    let now: @Sendable () -> Date

    public init(transport: HTTPTransport = URLSessionTransport(), apiKey: String = TCConstants.firebaseAPIKey,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.apiKey = apiKey
        self.now = now
    }

    public func signIn(email: String, password: String) async throws -> AuthTokens {
        let json = try await post("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword",
                                  body: ["email": email, "password": password, "returnSecureToken": true])
        return try Self.parseSignIn(json, now: now())
    }

    public func refresh(refreshToken: String) async throws -> AuthTokens {
        var request = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let escaped = refreshToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? refreshToken
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(escaped)".utf8)
        let json = try await run(request)
        return try Self.parseRefresh(json, now: now())
    }

    /// Sends Firebase's password-reset email.
    public func sendPasswordReset(email: String) async throws {
        _ = try await post("https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode",
                           body: ["requestType": "PASSWORD_RESET", "email": email])
    }

    // MARK: Parsing (static, for tests)

    public static func parseSignIn(_ json: [String: Any], now: Date) throws -> AuthTokens {
        guard let id = json["idToken"] as? String, let refresh = json["refreshToken"] as? String,
              let uid = json["localId"] as? String else { throw TCError.unexpectedResponse }
        return AuthTokens(idToken: id, refreshToken: refresh, uid: uid, expiresAt: now.addingTimeInterval(seconds(json["expiresIn"])))
    }

    public static func parseRefresh(_ json: [String: Any], now: Date) throws -> AuthTokens {
        guard let id = (json["id_token"] ?? json["access_token"]) as? String,
              let refresh = json["refresh_token"] as? String,
              let uid = json["user_id"] as? String else { throw TCError.unexpectedResponse }
        return AuthTokens(idToken: id, refreshToken: refresh, uid: uid, expiresAt: now.addingTimeInterval(seconds(json["expires_in"])))
    }

    private static func seconds(_ value: Any?) -> TimeInterval {
        if let s = value as? String, let d = Double(s) { return d }
        if let d = value as? Double { return d }
        return 3600
    }

    /// Firebase puts codes like `INVALID_LOGIN_CREDENTIALS` or `TOO_MANY_ATTEMPTS_TRY_LATER : …` in error.message.
    public static func mapError(message: String, status: Int) -> TCError {
        let code = message.components(separatedBy: " ").first ?? message
        switch code {
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS": return .invalidCredentials
        case "USER_DISABLED": return .userDisabled
        case "TOO_MANY_ATTEMPTS_TRY_LATER": return .tooManyAttempts
        case "INVALID_EMAIL", "MISSING_EMAIL": return .invalidEmail
        case "TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN", "USER_NOT_FOUND", "INVALID_GRANT_TYPE", "MISSING_REFRESH_TOKEN":
            return .sessionExpired
        default: return message.isEmpty ? .http(status) : .server(message)
        }
    }

    // MARK: Transport

    private func post(_ url: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(url)?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await run(request)
    }

    private func run(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 30
        let (data, status) = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw Self.mapError(message: message, status: status)
        }
        return json
    }
}
