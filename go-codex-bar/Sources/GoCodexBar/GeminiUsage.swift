import Foundation

enum GeminiUsageSource: String, CaseIterable, Sendable {
    case auto = "Auto"
    case antigravity = "Antigravity"
    case cli = "agy CLI"
}

struct GeminiUsageWindow: Identifiable, Sendable {
    let id: String
    let title: String
    let remainingPercent: Double?
    let resetDate: Date?
    let resetDescription: String?
}

struct GeminiAccountSnapshot: Identifiable, Sendable {
    let id: String
    let email: String?
    let plan: String?
    let source: String
    let windows: [GeminiUsageWindow]
    let updatedAt: Date

    var title: String { self.email ?? self.source }
}

enum GeminiUsageError: LocalizedError {
    case notRunning
    case authentication
    case noQuota
    case server(Int)
    case commandFailed
    case timeout
    case outputLimit
    case unsupportedCLI

    var errorDescription: String? {
        switch self {
        case .notRunning: "Open Antigravity or sign in with `agy`, then refresh."
        case .authentication: "Antigravity authentication is unavailable. Reopen Antigravity or sign in with `agy`, then refresh."
        case .noQuota: "Limits not available. Antigravity did not return measured quota."
        case let .server(status): "Antigravity usage returned HTTP \(status)."
        case .commandFailed: "Antigravity usage check failed. Open Antigravity or sign in with `agy`, then refresh."
        case .timeout: "Antigravity usage check timed out. Try refreshing again."
        case .outputLimit: "Antigravity usage response exceeded the size limit."
        case .unsupportedCLI: "Usage reports require agy 1.1.11 or newer. Update the Antigravity CLI."
        }
    }
}

enum GeminiUsageParser {
    static func parse(_ data: Data, source: String, identity: Data? = nil, cliReport: Bool = false) throws
        -> GeminiAccountSnapshot
    {
        let root = try self.object(data)
        try self.checkCode(root)
        let payload: [String: Any]
        if cliReport {
            guard root["status"] as? String == "SUCCESS",
                  let command = root["command"] as? [String: Any], command["name"] as? String == "usage",
                  let report = command["data"] as? [String: Any]
            else { throw GeminiUsageError.noQuota }
            payload = report
        } else {
            payload = root["response"] as? [String: Any] ?? root["summary"] as? [String: Any] ?? root
        }
        let status = ((identity.flatMap { try? self.object($0) })?["userStatus"] as? [String: Any])
            ?? root["userStatus"] as? [String: Any]
        let email = self.nonEmpty(status?["email"] as? String)
        let tier = status?["userTier"] as? [String: Any]
        let planInfo = (status?["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        let plan = self.nonEmpty(tier?["name"] as? String) ??
            ["planDisplayName", "displayName", "productName", "planName", "planShortName"]
                .compactMap { self.nonEmpty(planInfo?[$0] as? String) }.first
        var windows: [GeminiUsageWindow] = []
        if let groups = payload["groups"] as? [[String: Any]] {
            for group in groups {
                let name = group["displayName"] as? String ?? group["display_name"] as? String ?? "Quota"
                let family = self.family(name)
                for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                    guard let id = bucket["bucketId"] as? String ?? bucket["bucket_id"] as? String
                        ?? bucket["id"] as? String else { continue }
                    let remaining = bucket["remaining"] as? [String: Any]
                    let fraction = bucket["remainingFraction"] ?? bucket["remaining_fraction"]
                        ?? remaining?["remainingFraction"] ?? remaining?["remaining_fraction"]
                        ?? ((remaining?["case"] as? String == "remainingFraction") ? remaining?["value"] : nil)
                    let disabled = bucket["disabled"] as? Bool == true
                    let label = bucket["displayName"] as? String ?? bucket["display_name"] as? String ?? id
                    let cadence = self.cadence(bucket["window"] as? String ?? "\(id) \(label)")
                    windows.append(GeminiUsageWindow(
                        id: id, title: "\(family) \(cadence ?? label)",
                        remainingPercent: disabled ? nil : self.percent(fraction),
                        resetDate: self.date(bucket["resetTime"] ?? bucket["reset_time"]),
                        resetDescription: bucket["description"] as? String))
                }
            }
        } else if !cliReport {
            let configs = (status?["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"]
                as? [[String: Any]] ?? root["clientModelConfigs"] as? [[String: Any]] ?? []
            var pools: [String: GeminiUsageWindow] = [:]
            for config in configs {
                let model = (config["modelOrAlias"] as? [String: Any])?["model"] as? String ?? ""
                let label = config["label"] as? String ?? model
                let match = "\(model) \(label)".lowercased()
                guard !["image", "autocomplete", "lite"].contains(where: match.contains),
                      let quota = config["quotaInfo"] as? [String: Any] else { continue }
                let family: String
                if match.contains("gemini") { family = "Gemini" }
                else if match.contains("claude") || match.contains("gpt") { family = "Claude/GPT" }
                else { continue }
                let window = GeminiUsageWindow(
                    id: family, title: "\(family) Session", remainingPercent: self.percent(quota["remainingFraction"]),
                    resetDate: self.date(quota["resetTime"]), resetDescription: nil)
                if pools[family] == nil || (window.remainingPercent != nil &&
                    window.remainingPercent! < (pools[family]?.remainingPercent ?? .infinity))
                { pools[family] = window }
            }
            windows = Array(pools.values)
        }
        guard windows.contains(where: { $0.remainingPercent != nil }) else { throw GeminiUsageError.noQuota }
        var ids = Set<String>()
        windows = windows.filter { ids.insert($0.id).inserted }.sorted {
            func rank(_ window: GeminiUsageWindow) -> Int {
                (window.title.hasPrefix("Gemini") ? 0 : 2) + (window.title.contains("Weekly") ? 1 : 0)
            }
            return rank($0) == rank($1) ? $0.id < $1.id : rank($0) < rank($1)
        }
        return GeminiAccountSnapshot(
            id: email?.lowercased() ?? source, email: email, plan: plan, source: source,
            windows: windows, updatedAt: Date())
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiUsageError.noQuota
        }
        return value
    }

    private static func checkCode(_ value: [String: Any]) throws {
        guard let code = value["code"] else { return }
        guard ["0", "ok", "success"].contains(String(describing: code).lowercased()) else {
            throw GeminiUsageError.noQuota
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { return nil }
        return number.doubleValue * 100
    }

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            return ISO8601DateFormatter.codexDate(from: string)
                ?? Double(string).map { Date(timeIntervalSince1970: $0) }
        }
        return (value as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    private static func family(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("gemini") && !name.contains(where: \.isNumber) { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
        return name
    }

    private static func cadence(_ value: String) -> String? {
        let lower = value.lowercased().replacingOccurrences(of: "_", with: "-")
        if lower.contains("weekly") { return "Weekly" }
        if ["5h", "5-hour", "five-hour", "five hour", "session"].contains(where: lower.contains) { return "Session" }
        return nil
    }
}
