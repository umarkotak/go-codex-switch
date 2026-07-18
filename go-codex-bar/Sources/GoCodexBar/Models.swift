import Foundation

struct AuthFile: Codable, Sendable {
    let authMode: String?
    let openAIAPIKey: String?
    let tokens: AuthTokens
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

struct AuthTokens: Codable, Sendable {
    let idToken: String
    let accessToken: String
    let refreshToken: String?
    let accountID: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }
}

struct UsageResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: RateLimitDetails

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

struct RateLimitDetails: Decodable, Sendable {
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct UsageWindow: Decodable, Sendable {
    let usedPercent: Double
    let resetAt: Int64
    let limitWindowSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }

    var remainingPercent: Double {
        min(100, max(0, 100 - self.usedPercent))
    }

    var resetDate: Date? {
        guard self.resetAt > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(self.resetAt))
    }
}

struct ResetCreditsResponse: Decodable, Sendable {
    let availableCount: Int
    let credits: [ResetCredit]

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }
}

struct ResetCredit: Decodable, Identifiable, Sendable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.resetType = try container.decodeIfPresent(String.self, forKey: .resetType) ?? ""
        self.status = try container.decode(String.self, forKey: .status)
        self.grantedAt = Self.decodeDate(container: container, key: .grantedAt)
        self.expiresAt = Self.decodeDate(container: container, key: .expiresAt)
    }

    private static func decodeDate(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys) -> Date?
    {
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return ISO8601DateFormatter.codexDate(from: value)
    }
}

extension ISO8601DateFormatter {
    static func codexDate(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: value)
    }
}

struct StoredAccount: Sendable {
    let email: String
    let isActive: Bool
    let auth: AuthFile
}

struct AccountSnapshot: Identifiable, Sendable {
    var id: String { self.email }

    let email: String
    var isActive: Bool
    var usage: UsageResponse?
    var resetCredits: ResetCreditsResponse?
    var usageError: String?

    var primaryWindow: UsageWindow? { self.usage?.rateLimit.primaryWindow }
    var secondaryWindow: UsageWindow? { self.usage?.rateLimit.secondaryWindow }

    func availableResetCredits(at date: Date) -> [ResetCredit] {
        (self.resetCredits?.credits ?? [])
            .filter { credit in
                credit.status == "available" && (credit.expiresAt.map { $0 > date } ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (left?, right?):
                    if left != right { return left < right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.id < rhs.id
            }
    }
}

enum RecommendationEngine {
    static func recommendedEmail(accounts: [AccountSnapshot], now: Date) -> String? {
        let candidates = accounts.compactMap { account -> (email: String, remaining: Double, reset: Date)? in
            guard account.usageError == nil,
                  let window = account.primaryWindow,
                  let reset = window.resetDate,
                  reset > now
            else {
                return nil
            }
            return (account.email, window.remainingPercent, reset)
        }
        guard !candidates.isEmpty else { return nil }

        let over95 = candidates.filter { $0.remaining > 95 }
        return (over95.isEmpty ? candidates : over95)
            .min { lhs, rhs in
                if lhs.reset != rhs.reset { return lhs.reset < rhs.reset }
                return lhs.email < rhs.email
            }?
            .email
    }
}
