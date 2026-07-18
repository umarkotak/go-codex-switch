import Foundation

enum AuthStoreError: LocalizedError {
    case loginRequired
    case invalidToken
    case noSavedAccounts
    case accountNotFound(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            "Please sign in to Codex first."
        case .invalidToken:
            "The Codex identity token does not contain a valid email address."
        case .noSavedAccounts:
            "No saved Codex accounts were found."
        case let .accountNotFound(email):
            "The saved account \(email) was not found."
        }
    }
}

struct AuthStore: Sendable {
    let homeURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    var codexDirectory: URL { self.homeURL.appendingPathComponent(".codex", isDirectory: true) }
    var authURL: URL { self.codexDirectory.appendingPathComponent("auth.json") }
    var savedDirectory: URL { self.homeURL.appendingPathComponent(".go-codex-switch", isDirectory: true) }

    func listAccounts() throws -> [StoredAccount] {
        let activeEmail = try self.currentEmail()
        let emails = try self.savedEmails()
        return try emails.map { email in
            let auth = try self.readAuth(at: self.savedURL(for: email)).auth
            return StoredAccount(email: email, isActive: email == activeEmail, auth: auth)
        }
    }

    @discardableResult
    func saveCurrent() throws -> String {
        guard FileManager.default.fileExists(atPath: self.authURL.path) else {
            throw AuthStoreError.loginRequired
        }
        let value = try self.readAuth(at: self.authURL)
        let email = try Self.email(fromIDToken: value.auth.tokens.idToken)
        try FileManager.default.createDirectory(
            at: self.savedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.write(value.data, to: self.savedURL(for: email))
        return email
    }

    @discardableResult
    func load(email: String) throws -> Bool {
        if try self.currentEmail() == email {
            return false
        }
        if FileManager.default.fileExists(atPath: self.authURL.path) {
            _ = try self.saveCurrent()
        }
        let source = self.savedURL(for: email)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AuthStoreError.accountNotFound(email)
        }
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(
            at: self.codexDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.write(data, to: self.authURL)
        return true
    }

    @discardableResult
    func logout() throws -> String {
        let email = try self.saveCurrent()
        try FileManager.default.removeItem(at: self.authURL)
        return email
    }

    func currentEmail() throws -> String? {
        guard FileManager.default.fileExists(atPath: self.authURL.path) else { return nil }
        let auth = try self.readAuth(at: self.authURL).auth
        return try Self.email(fromIDToken: auth.tokens.idToken)
    }

    func savedEmails() throws -> [String] {
        guard FileManager.default.fileExists(atPath: self.savedDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: self.savedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .compactMap { url in
                let suffix = ".auth.json"
                guard url.lastPathComponent.hasSuffix(suffix) else { return nil }
                return String(url.lastPathComponent.dropLast(suffix.count))
            }
            .sorted()
    }

    private func readAuth(at url: URL) throws -> (auth: AuthFile, data: Data) {
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(AuthFile.self, from: data), data)
    }

    private func savedURL(for email: String) -> URL {
        self.savedDirectory.appendingPathComponent(email + ".auth.json")
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func email(fromIDToken token: String) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw AuthStoreError.invalidToken }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = object["email"] as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AuthStoreError.invalidToken
        }
        return email
    }
}
