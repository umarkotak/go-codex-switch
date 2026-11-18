import Foundation

enum ClaudeAuthStoreError: LocalizedError {
    case invalidCredentials
    case accountNotFound(String)
    case noSavedAccounts
    case keychainWriteFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Claude Code credentials are invalid. Run `claude` to sign in again."
        case let .accountNotFound(email):
            "The saved Claude account \(email) was not found."
        case .noSavedAccounts:
            "No saved Claude accounts were found."
        case let .keychainWriteFailed(status):
            "Could not update the Claude Code Keychain item (security exited with \(status))."
        }
    }
}

/// A Claude Code login that is signed in right now (as opposed to a saved copy).
struct LiveClaudeLogin: Sendable {
    enum Source: Sendable, Equatable {
        case file(URL)
        case keychain(ClaudeCodeKeychain.Item)
    }

    let source: Source
    let credentials: ClaudeOAuthCredentials
    let data: Data
    /// The login a plain `claude` uses. Others belong to a custom `CLAUDE_CONFIG_DIR`.
    let isDefault: Bool

    var label: String {
        switch self.source {
        case .file: "Signed in (credentials file)"
        case let .keychain(item) where item.isDefault: "Signed in (Keychain)"
        case let .keychain(item):
            "Signed in (Keychain\(item.service.dropFirst(ClaudeCodeKeychain.servicePrefix.count)), custom CLAUDE_CONFIG_DIR)"
        }
    }
}

struct ClaudeAuthStore: Sendable {
    let homeURL: URL
    let environment: [String: String]
    /// `nil` disables Keychain lookups (tests).
    let keychain: ClaudeCodeKeychain?

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: ClaudeCodeKeychain? = ClaudeCodeKeychain())
    {
        self.homeURL = homeURL
        self.environment = environment
        self.keychain = keychain
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
        try self.currentLogin()?.credentials
    }

    /// The login a plain `claude` uses: the credentials file when present, otherwise the default Keychain item.
    func currentLogin() throws -> LiveClaudeLogin? {
        if FileManager.default.fileExists(atPath: self.credentialsURL.path) {
            let (credentials, data) = try self.readCredentials(at: self.credentialsURL)
            return LiveClaudeLogin(source: .file(self.credentialsURL), credentials: credentials, data: data, isDefault: true)
        }
        guard let keychain else { return nil }
        let item = keychain.items().first(where: \.isDefault)
            ?? ClaudeCodeKeychain.Item(service: ClaudeCodeKeychain.servicePrefix, account: nil)
        guard let data = keychain.read(item) else { return nil }
        return LiveClaudeLogin(source: .keychain(item), credentials: try Self.decode(data), data: data, isDefault: true)
    }

    /// Every signed-in Claude Code login: the current one first, then any custom `CLAUDE_CONFIG_DIR` logins
    /// kept in the Keychain. Unreadable entries are skipped.
    func liveLogins() -> [LiveClaudeLogin] {
        var logins: [LiveClaudeLogin] = []
        if let current = try? self.currentLogin() {
            logins.append(current)
        }
        guard let keychain else { return logins }
        for item in keychain.items() where !logins.contains(where: { $0.source == .keychain(item) }) {
            guard let data = keychain.read(item), let credentials = try? Self.decode(data) else { continue }
            // With a credentials file, the default Keychain item is not what `claude` uses; skip it.
            if item.isDefault, !logins.isEmpty { continue }
            logins.append(LiveClaudeLogin(source: .keychain(item), credentials: credentials, data: data, isDefault: false))
        }
        return logins
    }

    func savedData(email: String) -> Data? {
        try? Data(contentsOf: self.savedURL(for: email))
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
            guard let credentials = try? self.readCredentials(at: url).credentials else { continue }
            accounts.append(StoredClaudeAccount(
                email: email,
                isActive: email == activeEmail || credentials.accessToken == activeToken,
                credentials: credentials))
        }
        return accounts.sorted { $0.email < $1.email }
    }

    func saveCurrent(email: String) throws {
        guard let data = try self.currentLogin()?.data else { throw ClaudeAuthStoreError.invalidCredentials }
        try self.save(data, email: email)
    }

    func save(_ data: Data, email: String) throws {
        _ = try Self.decode(data)
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
        try self.activate(Data(contentsOf: source))
        return true
    }

    /// Makes `data` the login a plain `claude` uses, in the same place Claude Code keeps it now.
    func activate(_ data: Data) throws {
        _ = try Self.decode(data)
        if let current = try? self.currentLogin(), case let .keychain(item) = current.source, let keychain {
            try keychain.write(data, to: item)
            guard let written = keychain.read(item), (try? Self.decode(written))?.accessToken == (try? Self.decode(data))?.accessToken else {
                throw ClaudeAuthStoreError.keychainWriteFailed(-1)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: self.credentialsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.write(data, to: self.credentialsURL)
    }

    static func decode(_ data: Data) throws -> ClaudeOAuthCredentials {
        guard let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data),
              let credentials = file.claudeAiOauth,
              !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ClaudeAuthStoreError.invalidCredentials
        }
        return credentials
    }

    private func readCredentials(at url: URL) throws -> (credentials: ClaudeOAuthCredentials, data: Data) {
        let data = try Data(contentsOf: url)
        return (try Self.decode(data), data)
    }

    func removeSavedAccount(email: String) throws {
        try FileManager.default.removeItem(at: self.savedURL(for: email))
    }

    private func savedURL(for email: String) -> URL {
        self.savedDirectory.appendingPathComponent(email + ".credentials.json")
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
