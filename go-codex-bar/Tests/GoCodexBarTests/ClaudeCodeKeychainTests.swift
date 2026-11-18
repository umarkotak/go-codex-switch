import Foundation
import XCTest
@testable import GoCodexBar

final class ClaudeCodeKeychainTests: XCTestCase {
    private let dump = """
    keychain: "/Users/me/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        "acct"<blob>="me"
        "svce"<blob>="Claude Code-credentials-1a2b3c4d"
    keychain: "/Users/me/Library/Keychains/login.keychain-db"
    class: "genp"
    attributes:
        "acct"<blob>="me"
        "svce"<blob>="Claude Safe Storage"
    keychain: "/Users/me/Library/Keychains/login.keychain-db"
    class: "inet"
    attributes:
        "svce"<blob>="Claude Code-credentials"
    keychain: "/Users/me/Library/Keychains/login.keychain-db"
    class: "genp"
    attributes:
        "acct"<blob>="me"
        "svce"<blob>="Claude Code-credentials"
    """

    func testParsesClaudeCodeItemsDefaultFirst() {
        XCTAssertEqual(ClaudeCodeKeychain.parseItems(self.dump), [
            .init(service: "Claude Code-credentials", account: "me"),
            .init(service: "Claude Code-credentials-1a2b3c4d", account: "me"),
        ])
    }

    func testReadsLiveLoginFromKeychainWhenNoCredentialsFile() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","refreshToken":"r"}}"#
        let dump = self.dump
        let keychain = ClaudeCodeKeychain { arguments, _ in
            if arguments.first == "dump-keychain" {
                return .init(status: 0, output: Data(dump.utf8))
            }
            if arguments.contains("Claude Code-credentials") {
                return .init(status: 0, output: Data((json + "\n").utf8))
            }
            return .init(status: 44, output: Data())
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ClaudeAuthStore(homeURL: home, environment: [:], keychain: keychain)

        let current = try XCTUnwrap(store.currentLogin())
        XCTAssertEqual(current.credentials.accessToken, "sk-ant-oat01-test")
        XCTAssertEqual(current.source, .keychain(.init(service: "Claude Code-credentials", account: "me")))
        XCTAssertEqual(store.liveLogins().count, 1)
    }
}
