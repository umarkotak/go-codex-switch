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

    func needsRefresh(at date: Date = Date()) -> Bool {
        guard let lastRefresh,
              let refreshedAt = ISO8601DateFormatter.codexDate(from: lastRefresh)
        else {
            return true
        }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return date.timeIntervalSince(refreshedAt) > eightDays
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

struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: ClaudeOAuthCredentials?
}

struct ClaudeOAuthCredentials: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
    }
}

struct ClaudeUsageResponse: Decodable, Sendable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    /// Saved "Reset for free" grants. Absent unless the request asked for `cedar_ember=1`.
    let resetStatus: ClaudeLimitResetStatus?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case resetStatus = "cedar_ember"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fiveHour = try container.decodeIfPresent(ClaudeUsageWindow.self, forKey: .fiveHour)
        self.sevenDay = try container.decodeIfPresent(ClaudeUsageWindow.self, forKey: .sevenDay)
        // A malformed reset block must never hide the quota windows.
        self.resetStatus = (try? container.decodeIfPresent(ClaudeLimitResetStatus.self, forKey: .resetStatus)) ?? nil
    }

    /// Expiry of each saved reset still usable at `date`, soonest first. `nil` means it never expires.
    func availableResetExpirations(at date: Date) -> [Date?] {
        self.resetStatus?.availableExpirations(at: date) ?? []
    }
}

/// The `cedar_ember` block of Claude's usage response. Only `eligible: true` yields resets; a grant with
/// an unreadable field is dropped without hiding the others, and an implausibly large inventory yields none.
struct ClaudeLimitResetStatus: Decodable, Sendable {
    static let maximumResets = 50
    static let maximumGrantRecords = 200

    struct Grant: Sendable {
        let resetsLeft: Int
        let startsAt: Date?
        let endsAt: Date?
        let paused: Bool

        func isAvailable(at date: Date) -> Bool {
            guard !self.paused, self.resetsLeft > 0 else { return false }
            if let startsAt, startsAt > date { return false }
            if let endsAt, endsAt <= date { return false }
            return true
        }
    }

    let eligible: Bool
    let grants: [Grant]

    private enum CodingKeys: String, CodingKey {
        case eligible
        case grants
    }

    init(eligible: Bool, grants: [Grant]) {
        self.eligible = eligible
        self.grants = grants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.eligible = try container.decode(Bool.self, forKey: .eligible)
        let records = try container.decodeIfPresent([LossyGrant].self, forKey: .grants) ?? []
        self.grants = records.count > Self.maximumGrantRecords ? [] : records.compactMap(\.grant)
    }

    func availableExpirations(at date: Date) -> [Date?] {
        guard self.eligible else { return [] }
        var expirations: [Date?] = []
        for grant in self.grants where grant.isAvailable(at: date) {
            guard grant.resetsLeft <= Self.maximumResets - expirations.count else { return [] }
            expirations.append(contentsOf: repeatElement(grant.endsAt, count: grant.resetsLeft))
        }
        return expirations.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (left?, right?): left < right
            case (_?, nil): true
            default: false
            }
        }
    }

    private struct LossyGrant: Decodable {
        let grant: Grant?

        init(from decoder: Decoder) throws {
            self.grant = try? Self.decodeGrant(from: decoder)
        }

        private enum Keys: String, CodingKey {
            case resetsLeft = "resets_left"
            case resetsTotal = "resets_total"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case paused
        }

        private static func decodeGrant(from decoder: Decoder) throws -> Grant {
            let container = try decoder.container(keyedBy: Keys.self)
            let resetsLeft = try container.decode(Int.self, forKey: .resetsLeft)
            let resetsTotal = try container.decodeIfPresent(Int.self, forKey: .resetsTotal)
            guard resetsLeft >= 0, resetsTotal.map({ $0 >= resetsLeft }) ?? true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .resetsLeft, in: container, debugDescription: "resets_left out of range")
            }
            return Grant(
                resetsLeft: resetsLeft,
                startsAt: try Self.decodeBound(container, key: .startsAt),
                endsAt: try Self.decodeBound(container, key: .endsAt),
                paused: try container.decode(Bool.self, forKey: .paused))
        }

        /// Absent or null is open; a supplied but unreadable bound is malformed, never unbounded.
        private static func decodeBound(_ container: KeyedDecodingContainer<Keys>, key: Keys) throws -> Date? {
            guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let date = ISO8601DateFormatter.codexDate(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container, debugDescription: "Unreadable ISO-8601 bound")
            }
            return date
        }
    }
}

struct ClaudeUsageWindow: Decodable, Sendable {
    let utilization: Double?
    let resetsAt: String?

    var remainingPercent: Double? {
        guard let utilization else { return nil }
        return min(100, max(0, 100 - utilization))
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return ISO8601DateFormatter.codexDate(from: resetsAt)
    }

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct StoredClaudeAccount: Sendable {
    let email: String
    let isActive: Bool
    let credentials: ClaudeOAuthCredentials
}

struct ClaudeAccountSnapshot: Identifiable, Sendable {
    var id: String { self.email }

    let email: String
    var isActive: Bool
    var usage: ClaudeUsageResponse?
    var usageError: String?
}

enum ClaudeRecommendationEngine {
    static func recommendedEmail(accounts: [ClaudeAccountSnapshot], now: Date) -> String? {
        let candidates = accounts.compactMap { account -> (email: String, remaining: Double, reset: Date)? in
            guard account.usageError == nil,
                  let window = account.usage?.fiveHour,
                  let remaining = window.remainingPercent,
                  let reset = window.resetDate,
                  reset > now
            else { return nil }
            return (account.email, remaining, reset)
        }
        guard !candidates.isEmpty else { return nil }
        let over95 = candidates.filter { $0.remaining > 95 }
        return (over95.isEmpty ? candidates : over95)
            .min { lhs, rhs in
                lhs.reset == rhs.reset ? lhs.email < rhs.email : lhs.reset < rhs.reset
            }?
            .email
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

struct CodexResetsResponse: Decodable, Sendable {
    let scheduled: CodexScheduledReset?
    let stats: CodexResetStatistics
}

struct CodexResetStatusError: Sendable {
    let message: String
    let responseCode: Int?
}

struct CodexScheduledReset: Decodable, Sendable {
    let scheduledFor: Date?
    let tweetURL: URL?

    enum CodingKeys: String, CodingKey {
        case scheduledFor = "scheduled_for"
        case tweetURL = "tweet_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(String.self, forKey: .scheduledFor) {
            self.scheduledFor = ISO8601DateFormatter.codexDate(from: value)
        } else {
            self.scheduledFor = nil
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .tweetURL) {
            self.tweetURL = URL(string: value)
        } else {
            self.tweetURL = nil
        }
    }
}

struct CodexResetStatistics: Decodable, Sendable {
    let lastResetAt: Date?
    let daysSinceLast: Double?

    enum CodingKeys: String, CodingKey {
        case lastResetAt = "last_reset_at"
        case daysSinceLast = "days_since_last"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(String.self, forKey: .lastResetAt) {
            self.lastResetAt = ISO8601DateFormatter.codexDate(from: value)
        } else {
            self.lastResetAt = nil
        }
        self.daysSinceLast = try container.decodeIfPresent(Double.self, forKey: .daysSinceLast)
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
