import Foundation

enum CodexAPIError: LocalizedError {
    case missingAccessToken
    case missingRefreshToken
    case unauthorized
    case refreshTokenExpired
    case refreshTokenRevoked
    case refreshTokenReused
    case server(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAccessToken: "Missing Codex access token."
        case .missingRefreshToken: "Missing Codex refresh token. Sign in again."
        case .unauthorized: "Codex authentication expired. Sign in again."
        case .refreshTokenExpired: "Refresh token expired. Sign in again."
        case .refreshTokenRevoked: "Refresh token was revoked. Sign in again."
        case .refreshTokenReused: "Refresh token was already used. Sign in again."
        case let .server(code): "Codex API returned HTTP \(code)."
        case .invalidResponse: "Codex API returned an invalid response."
        }
    }
}

struct CodexAPI: Sendable {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(auth: AuthFile) async throws -> UsageResponse {
        let request = try self.request(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            auth: auth,
            timeout: 30)
        let data = try await self.data(for: request)
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw CodexAPIError.invalidResponse
        }
    }

    func fetchResetCredits(auth: AuthFile) async throws -> ResetCreditsResponse {
        var request = try self.request(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            auth: auth,
            timeout: 8)
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        let data = try await self.data(for: request)
        do {
            let value = try JSONDecoder().decode(ResetCreditsResponse.self, from: data)
            guard value.availableCount >= 0 else { throw CodexAPIError.invalidResponse }
            return value
        } catch let error as CodexAPIError {
            throw error
        } catch {
            throw CodexAPIError.invalidResponse
        }
    }

    func refreshAuth(_ auth: AuthFile) async throws -> AuthFile {
        guard let refreshToken = auth.tokens.refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !refreshToken.isEmpty
        else {
            throw CodexAPIError.missingRefreshToken
        }

        var request = URLRequest(
            url: Self.refreshEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexAPIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw Self.refreshError(statusCode: http.statusCode, data: data)
        }
        guard let value = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data),
              !value.accessToken.isEmpty
        else {
            throw CodexAPIError.invalidResponse
        }

        return AuthFile(
            authMode: auth.authMode,
            openAIAPIKey: auth.openAIAPIKey,
            tokens: AuthTokens(
                idToken: value.idToken ?? auth.tokens.idToken,
                accessToken: value.accessToken,
                refreshToken: value.refreshToken ?? auth.tokens.refreshToken,
                accountID: auth.tokens.accountID),
            lastRefresh: ISO8601DateFormatter().string(from: Date()))
    }

    private func request(url: URL, auth: AuthFile, timeout: TimeInterval) throws -> URLRequest {
        let token = auth.tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CodexAPIError.missingAccessToken }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GoCodexBar", forHTTPHeaderField: "User-Agent")
        if let accountID = auth.tokens.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexAPIError.invalidResponse }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw CodexAPIError.unauthorized
        default: throw CodexAPIError.server(http.statusCode)
        }
    }

    private static func refreshError(statusCode: Int, data: Data) -> CodexAPIError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let errorCode: String? = if let error = object["error"] as? [String: Any] {
                error["code"] as? String
            } else if let error = object["error"] as? String {
                error
            } else {
                object["code"] as? String
            }

            switch errorCode?.lowercased() {
            case "refresh_token_expired": return .refreshTokenExpired
            case "refresh_token_reused": return .refreshTokenReused
            case "invalid_grant", "refresh_token_invalidated": return .refreshTokenRevoked
            default: break
            }
        }
        return statusCode == 401 ? .refreshTokenExpired : .server(statusCode)
    }
}

private struct TokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}
