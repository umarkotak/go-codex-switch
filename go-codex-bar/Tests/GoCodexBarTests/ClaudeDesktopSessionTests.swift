import CommonCrypto
import Foundation
import SQLite3
import XCTest
@testable import GoCodexBar

final class ClaudeDesktopSessionTests: XCTestCase {
    private let password = Data("test-safe-storage-password".utf8)
    private let sessionKey = "sk-ant-sid01-abc123_DEF-xyz"

    func testDecryptRoundTripWithoutHostHashPrefix() throws {
        let key = try ClaudeDesktopSessionReader.deriveKey(password: self.password)
        let encrypted = try self.encrypt(Data(self.sessionKey.utf8), key: key)
        let plaintext = try ClaudeDesktopSessionReader.decrypt(encrypted, key: key)
        XCTAssertEqual(ClaudeDesktopSessionReader.extractSessionKey(from: plaintext), self.sessionKey)
    }

    func testExtractsSessionKeyAfterChromiumHostHashPrefix() throws {
        let key = try ClaudeDesktopSessionReader.deriveKey(password: self.password)
        let hostHash = Data((0..<32).map { UInt8($0 &+ 1) })
        let encrypted = try self.encrypt(hostHash + Data(self.sessionKey.utf8), key: key)
        let plaintext = try ClaudeDesktopSessionReader.decrypt(encrypted, key: key)
        XCTAssertEqual(ClaudeDesktopSessionReader.extractSessionKey(from: plaintext), self.sessionKey)
    }

    func testDecryptRejectsUnknownVersionAndWrongKey() throws {
        let key = try ClaudeDesktopSessionReader.deriveKey(password: self.password)
        XCTAssertThrowsError(try ClaudeDesktopSessionReader.decrypt(Data("v99garbage-garbage".utf8), key: key))

        let encrypted = try self.encrypt(Data(self.sessionKey.utf8), key: key)
        let wrongKey = try ClaudeDesktopSessionReader.deriveKey(password: Data("other".utf8))
        let result = try? ClaudeDesktopSessionReader.decrypt(encrypted, key: wrongKey)
        XCTAssertNil(result.flatMap { ClaudeDesktopSessionReader.extractSessionKey(from: $0) })
    }

    func testReadsEncryptedSessionKeyFromCookieDatabase() throws {
        let home = try self.makeHome()
        let password = self.password
        defer { try? FileManager.default.removeItem(at: home) }
        let key = try ClaudeDesktopSessionReader.deriveKey(password: self.password)
        let encrypted = try self.encrypt(Data(self.sessionKey.utf8), key: key)
        let store = home.appendingPathComponent("Library/Application Support/Claude/Network/Cookies")
        try self.writeCookieDatabase(
            at: store,
            rows: [
                (host: ".claude.ai", name: "other", value: "", encrypted: encrypted),
                (host: ".claude.ai", name: "sessionKey", value: "", encrypted: encrypted),
            ])

        let reader = ClaudeDesktopSessionReader(homeURL: home, keychainPassword: { password })
        XCTAssertEqual(try reader.readSessionKey(), self.sessionKey)
    }

    func testPrefersPlaintextValueWithoutTouchingKeychain() throws {
        let home = try self.makeHome()
        let password = self.password
        defer { try? FileManager.default.removeItem(at: home) }
        let store = home.appendingPathComponent("Library/Application Support/Claude/Cookies")
        try self.writeCookieDatabase(
            at: store,
            rows: [(host: ".claude.ai", name: "sessionKey", value: self.sessionKey, encrypted: Data())])

        let reader = ClaudeDesktopSessionReader(homeURL: home, keychainPassword: { throw ClaudeDesktopSessionError.keychainItemMissing })
        XCTAssertEqual(try reader.readSessionKey(), self.sessionKey)
    }

    func testReportsMissingStoreAndSignedOutSession() throws {
        let home = try self.makeHome()
        let password = self.password
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = ClaudeDesktopSessionReader(homeURL: home, keychainPassword: { password })
        XCTAssertThrowsError(try reader.readSessionKey()) {
            XCTAssertEqual($0 as? ClaudeDesktopSessionError, .cookieStoreMissing)
        }

        let store = home.appendingPathComponent("Library/Application Support/Claude/Network/Cookies")
        try self.writeCookieDatabase(
            at: store,
            rows: [(host: ".example.com", name: "sessionKey", value: self.sessionKey, encrypted: Data())])
        XCTAssertThrowsError(try reader.readSessionKey()) {
            XCTAssertEqual($0 as? ClaudeDesktopSessionError, .noSessionKey)
        }
    }

    func testWebAPIParsing() {
        let organizations = Data("""
        [{"uuid":"api-org","capabilities":["api"]},{"uuid":"chat-org","capabilities":["chat","claude_pro"]}]
        """.utf8)
        XCTAssertEqual(ClaudeWebAPI.parseOrganizationID(organizations), "chat-org")
        XCTAssertNil(ClaudeWebAPI.parseOrganizationID(Data("[]".utf8)))

        XCTAssertEqual(ClaudeWebAPI.parseEmail(Data(#"{"email_address":" a@b.com "}"#.utf8)), "a@b.com")
        XCTAssertNil(ClaudeWebAPI.parseEmail(Data(#"{"email_address":""}"#.utf8)))

        let usage = Data("""
        {"five_hour":{"utilization":12.5,"resets_at":"2026-11-04T10:00:00.000000+00:00"},
         "seven_day":{"utilization":40,"resets_at":"2026-11-08T10:00:00Z"}}
        """.utf8)
        let decoded = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: usage)
        XCTAssertEqual(decoded?.fiveHour?.remainingPercent, 87.5)
        XCTAssertEqual(decoded?.sevenDay?.remainingPercent, 60)
    }

    // MARK: - Helpers

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeDesktopSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let input = [UInt8](plaintext)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes -> Int32 in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                keyBytes.baseAddress,
                key.count,
                iv,
                input,
                input.count,
                &output,
                output.count,
                &written)
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        return Data("v10".utf8) + Data(output.prefix(written))
    }

    private func writeCookieDatabase(
        at url: URL,
        rows: [(host: String, name: String, value: String, encrypted: Data)]) throws
    {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE cookies (
            host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, last_access_utc INTEGER DEFAULT 0)
        """, nil, nil, nil), SQLITE_OK)

        for row in rows {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO cookies (host_key, name, value, encrypted_value) VALUES (?, ?, ?, ?)",
                    -1, &statement, nil),
                SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, row.host, -1, transient)
            sqlite3_bind_text(statement, 2, row.name, -1, transient)
            sqlite3_bind_text(statement, 3, row.value, -1, transient)
            row.encrypted.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(row.encrypted.count), transient)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
    }
}
