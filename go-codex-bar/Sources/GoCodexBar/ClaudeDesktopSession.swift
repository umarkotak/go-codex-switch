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

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychainPassword: @escaping @Sendable () throws -> Data = ClaudeDesktopSessionReader.readKeychainPassword)
    {
        let support = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
        self.cookieStoreCandidates = [
            support.appendingPathComponent("Network", isDirectory: true).appendingPathComponent("Cookies"),
            support.appendingPathComponent("Cookies"),
        ]
        self.keychainPassword = keychainPassword
    }

    func readSessionKey() throws -> String {
        let fileManager = FileManager.default
        let stores = self.cookieStoreCandidates
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { Self.modificationDate($0) > Self.modificationDate($1) }
        guard !stores.isEmpty else { throw ClaudeDesktopSessionError.cookieStoreMissing }

        var firstError: ClaudeDesktopSessionError?
        for store in stores {
            do {
                if let key = try self.readSessionKey(from: store) { return key }
            } catch let error as ClaudeDesktopSessionError {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? ClaudeDesktopSessionError.noSessionKey
    }

    // MARK: - SQLite

    private struct CookieRow {
        let value: String
        let encryptedValue: Data
    }

    private func readSessionKey(from store: URL) throws -> String? {
        let rows = try Self.sessionRows(in: store)
        var derivedKey: Data?
        var decryptError: ClaudeDesktopSessionError?
        for row in rows {
            let plain = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.hasPrefix(Self.sessionKeyPrefix) { return plain }
            guard !row.encryptedValue.isEmpty else { continue }
            if derivedKey == nil {
                derivedKey = try Self.deriveKey(password: self.keychainPassword())
            }
            do {
                let plaintext = try Self.decrypt(row.encryptedValue, key: derivedKey!)
                if let key = Self.extractSessionKey(from: plaintext) { return key }
            } catch let error as ClaudeDesktopSessionError {
                decryptError = decryptError ?? error
            }
        }
        if let decryptError { throw decryptError }
        return nil
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

        let sql = """
        SELECT value, encrypted_value FROM cookies
        WHERE name = 'sessionKey' AND host_key LIKE '%claude.ai'
        ORDER BY last_access_utc DESC
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
            rows.append(CookieRow(value: value, encryptedValue: encrypted))
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

    private static func modificationDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
}
