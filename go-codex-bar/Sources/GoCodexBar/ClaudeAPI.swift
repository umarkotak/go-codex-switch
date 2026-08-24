import Foundation

enum ClaudeAPIError: LocalizedError {
    case unauthorized
    case rateLimited
    case server(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Claude authentication expired. Run `claude` to sign in again."
        case .rateLimited: "Claude quota endpoint is rate limited. Try again in a few minutes."
        case let .server(code): "Claude API returned HTTP \(code)."
        case .invalidResponse: "Claude API returned an invalid response."
        }
    }
}

struct ClaudeAPI: Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(credentials: ClaudeOAuthCredentials) async throws -> ClaudeUsageResponse {
        let request = self.request(url: Self.usageURL, credentials: credentials, includesBeta: true)

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.invalidResponse }
        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            } catch {
                throw ClaudeAPIError.invalidResponse
            }
        case 401: throw ClaudeAPIError.unauthorized
        case 429: throw ClaudeAPIError.rateLimited
        default: throw ClaudeAPIError.server(http.statusCode)
        }
    }

    func fetchEmail(credentials: ClaudeOAuthCredentials) async throws -> String? {
        let request = self.request(url: Self.profileURL, credentials: credentials, includesBeta: false)
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.invalidResponse }
        switch http.statusCode {
        case 200:
            let profile = try JSONDecoder().decode(ClaudeProfileResponse.self, from: data)
            return profile.account?.emailAddress ?? profile.emailAddress ?? profile.email
        case 401: throw ClaudeAPIError.unauthorized
        case 429: throw ClaudeAPIError.rateLimited
        default: throw ClaudeAPIError.server(http.statusCode)
        }
    }

    private func request(
        url: URL,
        credentials: ClaudeOAuthCredentials,
        includesBeta: Bool) -> URLRequest
    {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if includesBeta {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        }
        return request
    }
}

private struct ClaudeProfileResponse: Decodable {
    let account: Account?
    let emailAddress: String?
    let email: String?

    struct Account: Decodable {
        let emailAddress: String?

        enum CodingKeys: String, CodingKey {
            case emailAddress
            case email
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
                ?? container.decodeIfPresent(String.self, forKey: .email)
        }
    }

    enum CodingKeys: String, CodingKey {
        case account
        case emailAddress
        case email
    }
}
