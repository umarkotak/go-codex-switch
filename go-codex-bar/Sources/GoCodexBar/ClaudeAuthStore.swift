import Foundation

enum ClaudeAuthStoreError: LocalizedError {
    case invalidCredentials
    case accountNotFound(String)
    case noSavedAccounts

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Claude Code credentials are invalid. Run `claude` to sign in again."
        case let .accountNotFound(email):
            "The saved Claude account \(email) was not found."
        case .noSavedAccounts:
            "No saved Claude accounts were found."
        }
    }
}

struct ClaudeAuthStore: Sendable {
    let homeURL: URL
    let environment: [String: String]

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.homeURL = homeURL
        self.environment = environment
    }

    var credentialsURL: URL {
        let directory: String? = if let secureStorage = self.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            secureStorage.isEmpty ? nil : secureStorage
        } else {
            self.environment["CLAUDE_CONFIG_DIR"]
        }

        if let directory, !directory.isEmpty {
            return URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(".credentials.json")
        }
        return self.homeURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    var savedDirectory: URL {
        self.homeURL
            .appendingPathComponent(".go-codex-switch", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
    }

    func currentCredentials() throws -> ClaudeOAuthCredentials? {
        guard FileManager.default.fileExists(atPath: self.credentialsURL.path) else { return nil }
        return try self.readCredentials(at: self.credentialsURL).credentials
    }

    func listAccounts(activeEmail: String?, activeToken: String?) throws -> [StoredClaudeAccount] {
        guard FileManager.default.fileExists(atPath: self.savedDirectory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: self.savedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        var accounts: [StoredClaudeAccount] = []
        for url in urls {
            let suffix = ".credentials.json"
            guard url.lastPathComponent.hasSuffix(suffix) else { continue }
            let email = String(url.lastPathComponent.dropLast(suffix.count))
            let credentials = try self.readCredentials(at: url).credentials
            accounts.append(StoredClaudeAccount(
                email: email,
                isActive: email == activeEmail || credentials.accessToken == activeToken,
                credentials: credentials))
        }
        return accounts.sorted { $0.email < $1.email }
    }

    func saveCurrent(email: String) throws {
        let data = try Data(contentsOf: self.credentialsURL)
        try FileManager.default.createDirectory(
            at: self.savedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.write(data, to: self.savedURL(for: email))
    }

    @discardableResult
    func load(email: String, activeEmail: String?) throws -> Bool {
        if email == activeEmail { return false }
        let source = self.savedURL(for: email)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ClaudeAuthStoreError.accountNotFound(email)
        }
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(
            at: self.credentialsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.write(data, to: self.credentialsURL)
        return true
    }

    private func readCredentials(at url: URL) throws -> (credentials: ClaudeOAuthCredentials, data: Data) {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(ClaudeCredentialsFile.self, from: data)
        guard let credentials = file.claudeAiOauth,
              !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ClaudeAuthStoreError.invalidCredentials
        }
        return (credentials, data)
    }

    private func savedURL(for email: String) -> URL {
        self.savedDirectory.appendingPathComponent(email + ".credentials.json")
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
