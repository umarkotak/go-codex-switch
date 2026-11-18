import CommonCrypto
import Foundation
import Security
import SQLite3

enum ClaudeDesktopSessionError: LocalizedError, Equatable {
    /// Claude.app has never been launched, so it has no cookie store.
    case cookieStoreMissing
    /// The store exists but holds no claude.ai session (signed out).
    case noSessionKey
    case keychainDenied(Int32)
    case keychainItemMissing
    case decryptFailed
    case database(String)

    var errorDescription: String? {
        switch self {
        case .cookieStoreMissing:
            "Claude desktop app data was not found."
        case .noSessionKey:
            "No Claude desktop session found. Open Claude and sign in."
        case let .keychainDenied(status):
            "Keychain access to \"Claude Safe Storage\" was denied (status \(status)). Allow it to read Claude usage."
        case .keychainItemMissing:
            "The \"Claude Safe Storage\" Keychain item was not found. Open Claude once and sign in."
        case .decryptFailed:
            "Could not decrypt the Claude desktop session cookie."
        case let .database(message):
            "Could not read the Claude desktop cookie store: \(message)"
        }
    }
}

/// Reads the `sessionKey` cookie that Claude.app (an Electron/Chromium app) keeps for claude.ai.
///
/// Chromium on macOS stores cookie values as `v10` + AES-128-CBC ciphertext. The key is derived with
/// PBKDF2-HMAC-SHA1 (salt `saltysalt`, 1003 rounds) from the app's "Safe Storage" Keychain password.
/// This only reads; nothing is written to the app's data or Keychain.
struct ClaudeDesktopSessionReader: Sendable {
    static let keychainService = "Claude Safe Storage"
    static let keychainAccount = "Claude Key"
    static let sessionKeyPrefix = "sk-ant-"

    let cookieStoreCandidates: [URL]
    let keychainPassword: @Sendable () throws -> Data

    static func defaultDataDirectory(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
    }

    /// Chromium keeps cookies in `Network/Cookies` (newer) or `Cookies` (older) under the user data directory.
    /// Electron session partitions (`Partitions/<name>/...`) have their own stores, so those are included too.
    static func cookieStoreURLs(in dataDirectory: URL) -> [URL] {
        func stores(in directory: URL) -> [URL] {
            [
                directory.appendingPathComponent("Network", isDirectory: true).appendingPathComponent("Cookies"),
                directory.appendingPathComponent("Cookies"),
            ]
        }
        var urls = stores(in: dataDirectory)
        let partitions = dataDirectory.appendingPathComponent("Partitions", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: partitions.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            urls += stores(in: partitions.appendingPathComponent(name, isDirectory: true))
        }
        return urls
    }

    /// Hosts whose `sessionKey` is the claude.ai chat session. Console hosts (platform.claude.com) are excluded.
    static let sessionHosts = ["claude.ai", ".claude.ai", "claude.com", ".claude.com"]

    init(
        homeURL: URL,
        keychainPassword: @escaping @Sendable () throws -> Data = ClaudeDesktopSessionReader.readKeychainPassword)
    {
        self.init(
            dataDirectory: Self.defaultDataDirectory(homeURL: homeURL),
            keychainPassword: keychainPassword)
    }

    init(
        dataDirectory: URL = ClaudeDesktopSessionReader.defaultDataDirectory(),
        keychainPassword: @escaping @Sendable () throws -> Data = ClaudeDesktopSessionReader.readKeychainPassword)
    {
        self.cookieStoreCandidates = Self.cookieStoreURLs(in: dataDirectory)
        self.keychainPassword = keychainPassword
    }

    /// The newest sign-in's session key.
    func readSessionKey() throws -> String {
        try self.readSessionKeys()[0]
    }

    /// Every unexpired session key in the profile, newest sign-in first. An old account's cookie can stay
    /// behind (and stay valid) after signing in to another account, so callers should prefer the first key
    /// that works rather than whichever store happens to be listed first.
    func readSessionKeys() throws -> [String] {
        let fileManager = FileManager.default
        let stores = self.cookieStoreCandidates.filter { fileManager.fileExists(atPath: $0.path) }
        guard !stores.isEmpty else { throw ClaudeDesktopSessionError.cookieStoreMissing }

        var found: [(key: String, created: Int64, accessed: Int64)] = []
        var firstError: ClaudeDesktopSessionError?
        var derivedKey: Data?
        for store in stores {
            do {
                for row in try Self.sessionRows(in: store) {
                    do {
                        if let key = try self.sessionKey(from: row, derivedKey: &derivedKey) {
                            found.append((key, row.created, row.accessed))
                        }
                    } catch let error as ClaudeDesktopSessionError {
                        switch error {
                        case .keychainDenied, .keychainItemMissing:
                            throw error // Don't ask the Keychain again for every remaining cookie.
                        default:
                            firstError = firstError ?? error
                        }
                    }
                }
            } catch ClaudeDesktopSessionError.keychainDenied(let status) {
                throw ClaudeDesktopSessionError.keychainDenied(status)
            } catch ClaudeDesktopSessionError.keychainItemMissing {
                throw ClaudeDesktopSessionError.keychainItemMissing
            } catch let error as ClaudeDesktopSessionError {
                firstError = firstError ?? error
            }
        }
        let ordered = found.sorted { lhs, rhs in
            lhs.created == rhs.created ? lhs.accessed > rhs.accessed : lhs.created > rhs.created
        }
        var keys: [String] = []
        for entry in ordered where !keys.contains(entry.key) {
            keys.append(entry.key)
        }
        guard !keys.isEmpty else { throw firstError ?? ClaudeDesktopSessionError.noSessionKey }
        return keys
    }

    // MARK: - SQLite

    private struct CookieRow {
        let value: String
        let encryptedValue: Data
        let created: Int64
        let accessed: Int64
    }

    private func sessionKey(from row: CookieRow, derivedKey: inout Data?) throws -> String? {
        let plain = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.hasPrefix(Self.sessionKeyPrefix) { return plain }
        guard !row.encryptedValue.isEmpty else { return nil }
        if derivedKey == nil {
            derivedKey = try Self.deriveKey(password: self.keychainPassword())
        }
        let plaintext = try Self.decrypt(row.encryptedValue, key: derivedKey!)
        return Self.extractSessionKey(from: plaintext)
    }

    private static func sessionRows(in store: URL) throws -> [CookieRow] {
        // The app keeps the database open (WAL mode), so query a private copy that includes the WAL.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("go-codex-bar-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let copy = directory.appendingPathComponent("Cookies")
        do {
            try FileManager.default.copyItem(at: store, to: copy)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: store.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try? FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
                }
            }
        } catch {
            throw ClaudeDesktopSessionError.database(error.localizedDescription)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ClaudeDesktopSessionError.database(message)
        }
        defer { sqlite3_close(db) }

        // Chromium times are microseconds since 1601-01-01. `expires_utc = 0` is a session cookie.
        let now = (Int64(Date().timeIntervalSince1970) + 11_644_473_600) * 1_000_000
        let hosts = Self.sessionHosts.map { "'\($0)'" }.joined(separator: ", ")
        let sql = """
        SELECT value, encrypted_value, creation_utc, last_access_utc FROM cookies
        WHERE name = 'sessionKey' AND host_key IN (\(hosts))
          AND (expires_utc = 0 OR expires_utc > \(now))
        ORDER BY creation_utc DESC, last_access_utc DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClaudeDesktopSessionError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [CookieRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let value = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let length = Int(sqlite3_column_bytes(statement, 1))
            var encrypted = Data()
            if length > 0, let bytes = sqlite3_column_blob(statement, 1) {
                encrypted = Data(bytes: bytes, count: length)
            }
            rows.append(CookieRow(
                value: value,
                encryptedValue: encrypted,
                created: sqlite3_column_int64(statement, 2),
                accessed: sqlite3_column_int64(statement, 3)))
        }
        return rows
    }

    // MARK: - Chromium cookie decryption

    static func deriveKey(password: Data) throws -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = password.withUnsafeBytes { passwordBytes -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.bindMemory(to: Int8.self).baseAddress,
                password.count,
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key,
                key.count)
        }
        guard status == Int32(kCCSuccess) else { throw ClaudeDesktopSessionError.decryptFailed }
        return Data(key)
    }

    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        let versionPrefixLength = 3
        guard encrypted.count > versionPrefixLength,
              let version = String(data: encrypted.prefix(versionPrefixLength), encoding: .utf8),
              version == "v10" || version == "v11"
        else { throw ClaudeDesktopSessionError.decryptFailed }

        let ciphertext = Array(encrypted.dropFirst(versionPrefixLength))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes -> Int32 in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                keyBytes.baseAddress,
                key.count,
                iv,
                ciphertext,
                ciphertext.count,
                &output,
                output.count,
                &written)
        }
        guard status == Int32(kCCSuccess) else { throw ClaudeDesktopSessionError.decryptFailed }
        return Data(output.prefix(written))
    }

    /// Newer Chromium prepends a 32-byte SHA-256 of the cookie's host to the plaintext, so locate the
    /// `sk-ant-` marker rather than assuming where the value starts.
    static func extractSessionKey(from plaintext: Data) -> String? {
        let marker = Array(Self.sessionKeyPrefix.utf8)
        let bytes = [UInt8](plaintext)
        guard bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) where Array(bytes[start..<(start + marker.count)]) == marker {
            let value = String(decoding: bytes[start...], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Keychain

    @Sendable
    static func readKeychainPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { throw ClaudeDesktopSessionError.keychainItemMissing }
            return data
        case errSecItemNotFound:
            throw ClaudeDesktopSessionError.keychainItemMissing
        default:
            throw ClaudeDesktopSessionError.keychainDenied(status)
        }
    }
}
