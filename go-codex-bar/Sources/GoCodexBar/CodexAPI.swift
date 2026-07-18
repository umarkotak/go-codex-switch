import Foundation

enum CodexAPIError: LocalizedError {
    case missingAccessToken
    case unauthorized
    case server(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAccessToken: "Missing Codex access token."
        case .unauthorized: "Codex authentication expired. Sign in again."
        case let .server(code): "Codex API returned HTTP \(code)."
        case .invalidResponse: "Codex API returned an invalid response."
        }
    }
}

struct CodexAPI: Sendable {
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
}
