import Foundation
import XCTest
@testable import GoCodexBar

final class CodexRestarterTests: XCTestCase {
    func testRestartTargetsBundleIdentifierAcrossRename() async throws {
        let commands = RestartCommands()
        try await CodexRestarter.restart(run: { commands.append($0, $1) }, forceQuit: {
            XCTFail("A successful graceful quit should not force quit")
        })
        XCTAssertEqual(commands.values, [
            ["/usr/bin/osascript", "-e", "quit app id \"com.openai.codex\""],
            ["/usr/bin/open", "-b", "com.openai.codex"],
        ])
    }

    func testGracefulQuitFailureUsesFallbackBeforeReopening() async throws {
        let commands = RestartCommands()
        try await CodexRestarter.restart(run: { executable, arguments in
            commands.append(executable, arguments)
            if executable == "/usr/bin/osascript" {
                throw CodexRestarterError.commandFailed("Automation denied")
            }
        }, forceQuit: { commands.append("forceQuit", []) })
        XCTAssertEqual(commands.values, [
            ["/usr/bin/osascript", "-e", "quit app id \"com.openai.codex\""],
            ["forceQuit"],
            ["/usr/bin/open", "-b", "com.openai.codex"],
        ])
    }

    func testForceQuitFailureDoesNotReopenAnUnchangedProcess() async {
        let commands = RestartCommands()
        do {
            try await CodexRestarter.restart(run: { executable, arguments in
                commands.append(executable, arguments)
                throw CodexRestarterError.commandFailed("Automation denied")
            }, forceQuit: { throw CodexRestarterError.commandFailed("Cannot terminate") })
            XCTFail("Expected restart to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Cannot terminate")
        }
        XCTAssertEqual(commands.values.count, 1)
    }

    func testLaunchFailureIsReported() async {
        do {
            try await CodexRestarter.restart(run: { executable, _ in
                if executable == "/usr/bin/open" {
                    throw CodexRestarterError.commandFailed("Application not installed")
                }
            }, forceQuit: { XCTFail("Unexpected force quit") })
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Application not installed")
        }
    }
}

private final class RestartCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    var values: [[String]] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }

    func append(_ executable: String, _ arguments: [String]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.recorded.append([executable] + arguments)
    }
}
