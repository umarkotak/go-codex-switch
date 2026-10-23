import XCTest
@testable import GoCodexBar

@MainActor
final class CodexRestarterTests: XCTestCase {
    func testWaitsForExitBeforeLaunching() async throws {
        var running = true
        var quitting = false
        var checks = 0
        var requests: [Bool] = []
        try await CodexRestarter.restart(requestQuit: { force in
            requests.append(force)
            quitting = true
        }, isRunning: {
            if quitting {
                checks += 1
                if checks == 3 { running = false }
            }
            return running
        }, launch: {
            XCTAssertFalse(running, "Reopening a running app only activates the existing process")
            quitting = false
            running = true
        })
        XCTAssertEqual(requests, [false])
        XCTAssertEqual(checks, 3)
        XCTAssertTrue(running)
    }

    func testGracefulQuitThatDoesNotExitUsesForceQuit() async throws {
        var running = true
        var requests: [Bool] = []
        try await CodexRestarter.restart(requestQuit: { force in
            requests.append(force)
            if force { running = false }
        }, isRunning: { running }, launch: {
            XCTAssertFalse(running)
            running = true
        }, timeout: .zero)
        XCTAssertEqual(requests, [false, true])
        XCTAssertTrue(running)
    }

    func testRefusesToLaunchWhileOldProcessIsRunning() async {
        var launched = false
        do {
            try await CodexRestarter.restart(requestQuit: { _ in }, isRunning: { true }, launch: {
                launched = true
            }, timeout: .zero)
            XCTFail("Expected termination failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not exit"))
        }
        XCTAssertFalse(launched)
    }

    func testLaunchFailureIsReported() async {
        do {
            try await CodexRestarter.restart(requestQuit: { _ in }, isRunning: { false }, launch: {
                throw CodexRestarterError.commandFailed("Application not installed")
            })
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Application not installed")
        }
    }

    func testSuccessfulOpenCommandWithoutNewProcessIsNotReportedAsRestart() async {
        do {
            try await CodexRestarter.restart(requestQuit: { _ in }, isRunning: { false }, launch: {}, timeout: .zero)
            XCTFail("Expected startup verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not start"))
        }
    }

    func testStartsAppWhenItWasNotRunning() async throws {
        var running = false
        try await CodexRestarter.restart(requestQuit: { _ in }, isRunning: { running }, launch: {
            running = true
        })
        XCTAssertTrue(running)
    }
}
