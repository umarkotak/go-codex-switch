import Foundation

enum ClaudeWebAPIError: LocalizedError {
    case unauthorized
    case cloudflareChallenge
    case rateLimited
    case noOrganization
    case server(Int)
    case invalidResponse
    /// 400/403 on a request that is allowed to fall back to a simpler form.
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Claude desktop session expired. Open Claude and sign in again."
        case .cloudflareChallenge: "claude.ai blocked the request with a browser check. Try again on another network."
        case .rateLimited: "claude.ai usage endpoint is rate limited. Try again in a few minutes."
        case .noOrganization: "No Claude organization was found for this session."
        case let .server(code): "claude.ai returned HTTP \(code)."
        case .invalidResponse: "claude.ai returned an invalid response."
        case let .rejected(code): "claude.ai rejected the request (HTTP \(code))."
        }
    }
}

/// Quota lookup for a claude.ai web session (the account signed in to Claude.app).
///
/// - `GET /api/organizations` -> organization UUID
/// - `GET /api/organizations/{id}/usage` -> `five_hour` / `seven_day` windows (same shape as the OAuth endpoint)
/// - `GET /api/account` -> email
struct ClaudeWebAPI: Sendable {
    private static let baseURL = "https://claude.ai/api"

    let session: URLSession

    init(session: URLSession = ClaudeWebAPI.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func fetchUsage(sessionKey: String) async throws -> ClaudeUsageResponse {
        let organizationID = try await self.fetchOrganizationID(sessionKey: sessionKey)
        // `cedar_ember=1` adds the saved limit-reset grants. If the server rejects the extra query, retry
        // without it so the quota windows still load.
        let path = "/organizations/\(organizationID)/usage"
        let data: Data
        do {
            data = try await self.get(path + "?cedar_ember=1", sessionKey: sessionKey, fallbackStatuses: [400, 403])
        } catch ClaudeWebAPIError.rejected {
            data = try await self.get(path, sessionKey: sessionKey)
        }
        do {
            return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw ClaudeWebAPIError.invalidResponse
        }
    }

    func fetchEmail(sessionKey: String) async throws -> String? {
        let data = try await self.get("/account", sessionKey: sessionKey)
        return Self.parseEmail(data)
    }

    func fetchOrganizationID(sessionKey: String) async throws -> String {
        let data = try await self.get("/organizations", sessionKey: sessionKey)
        guard let id = Self.parseOrganizationID(data) else { throw ClaudeWebAPIError.noOrganization }
        return id
    }

    static func parseEmail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let value = (json["email_address"] as? String) ?? (json["email"] as? String)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Prefer an organization with chat capability, then any non API-only organization.
    static func parseOrganizationID(_ data: Data) -> String? {
        guard let organizations = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        func capabilities(_ organization: [String: Any]) -> Set<String> {
            Set((organization["capabilities"] as? [String] ?? []).map { $0.lowercased() })
        }
        let selected = organizations.first { capabilities($0).contains("chat") }
            ?? organizations.first { capabilities($0) != ["api"] }
            ?? organizations.first
        return selected?["uuid"] as? String
    }

    private func get(_ path: String, sessionKey: String, fallbackStatuses: Set<Int> = []) async throws -> Data {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeWebAPIError.invalidResponse }
        if fallbackStatuses.contains(http.statusCode), !Self.isCloudflareChallenge(http, data: data) {
            throw ClaudeWebAPIError.rejected(http.statusCode)
        }
        switch http.statusCode {
        case 200: return data
        case 401: throw ClaudeWebAPIError.unauthorized
        case 403:
            throw Self.isCloudflareChallenge(http, data: data)
                ? ClaudeWebAPIError.cloudflareChallenge
                : ClaudeWebAPIError.unauthorized
        case 429: throw ClaudeWebAPIError.rateLimited
        default: throw ClaudeWebAPIError.server(http.statusCode)
        }
    }

    private static func isCloudflareChallenge(_ response: HTTPURLResponse, data: Data) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("challenge") == .orderedSame
        {
            return true
        }
        let prefix = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        return prefix.localizedCaseInsensitiveContains("Just a moment")
    }
}
