import Foundation
import XCTest
@testable import GoCodexBar

final class SavedAccountRemovalTests: XCTestCase {
    func testRemovalTargetsSavedCopiesOnly() throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: home) }
        let codex = AuthStore(homeURL: home)
        let claude = ClaudeAuthStore(homeURL: home, environment: [:])
        let email = "saved@example.com"
        let savedCodex = codex.savedDirectory.appendingPathComponent(email + ".auth.json")
        let savedClaude = claude.savedDirectory.appendingPathComponent(email + ".credentials.json")

        for url in [savedCodex, savedClaude, codex.authURL, claude.credentialsURL] {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }

        try codex.removeSavedAccount(email: email)
        try claude.removeSavedAccount(email: email)

        XCTAssertFalse(files.fileExists(atPath: savedCodex.path))
        XCTAssertFalse(files.fileExists(atPath: savedClaude.path))
        XCTAssertTrue(files.fileExists(atPath: codex.authURL.path))
        XCTAssertTrue(files.fileExists(atPath: claude.credentialsURL.path))
    }
}
