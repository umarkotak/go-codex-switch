import Foundation
import XCTest
@testable import GoCodexBar

final class ClaudeDesktopProfilesTests: XCTestCase {
    func testParsesMainClaudeProcessesAndSkipsHelpers() {
        let output = """
          101 /Applications/Claude.app/Contents/MacOS/Claude
          102 /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer --user-data-dir=/x
          103 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/Users/u/.go-codex-switch/claude-profiles/account-2
          104 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/Users/u/My Profiles/work --foo=bar
          105 /usr/bin/vim notes.txt
        """
        let instances = ClaudeDesktopLauncher.parseInstances(psOutput: output)
        XCTAssertEqual(instances, [
            .init(pid: 101, profileDirectory: nil),
            .init(pid: 103, profileDirectory: "/Users/u/.go-codex-switch/claude-profiles/account-2"),
            .init(pid: 104, profileDirectory: "/Users/u/My Profiles/work"),
        ])
    }

    func testMatchesInstancesToProfiles() {
        let defaultProfile = ClaudeDesktopProfile(
            name: "default", dataDirectory: URL(fileURLWithPath: "/Users/u/Library/Application Support/Claude"), isDefault: true)
        let second = ClaudeDesktopProfile(
            name: "account-2", dataDirectory: URL(fileURLWithPath: "/p/account-2"), isDefault: false)
        let instances: [ClaudeDesktopLauncher.Instance] = [
            .init(pid: 1, profileDirectory: nil),
            .init(pid: 2, profileDirectory: "/p/account-2/"),
        ]
        XCTAssertEqual(ClaudeDesktopLauncher.instance(for: defaultProfile, in: instances)?.pid, 1)
        XCTAssertEqual(ClaudeDesktopLauncher.instance(for: second, in: instances)?.pid, 2)
        XCTAssertNil(ClaudeDesktopLauncher.instance(for: second, in: [.init(pid: 1, profileDirectory: nil)]))
        XCTAssertNil(ClaudeDesktopLauncher.instance(for: defaultProfile, in: [.init(pid: 2, profileDirectory: "/p/account-2")]))
    }

    func testListsDefaultAndSignedInProfilesAndPicksNextName() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeDesktopProfilesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClaudeDesktopProfileStore(homeURL: home)
        XCTAssertTrue(store.listProfiles().isEmpty)
        XCTAssertEqual(store.nextProfileName(), "account-2")

        func touch(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }
        try touch(store.defaultDataDirectory.appendingPathComponent("Network/Cookies"))
        try touch(store.profilesDirectory.appendingPathComponent("account-2/Cookies"))
        _ = try store.createProfile(named: "account-3") // created but never launched: no cookie store yet

        XCTAssertEqual(store.listProfiles().map(\.name), ["default", "account-2"])
        XCTAssertEqual(store.listProfiles().map(\.isDefault), [true, false])
        XCTAssertEqual(store.nextProfileName(), "account-4")
    }
}
