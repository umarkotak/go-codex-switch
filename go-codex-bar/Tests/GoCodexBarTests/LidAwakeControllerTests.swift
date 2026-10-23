import XCTest
@testable import GoCodexBar

final class LidAwakeControllerTests: XCTestCase {
    func testStatusParsing() throws {
        XCTAssertTrue(try LidAwakeController.parseStatus("System-wide power settings:\n SleepDisabled\t\t1\n"))
        XCTAssertFalse(try LidAwakeController.parseStatus("System-wide power settings:\n SleepDisabled 0\n"))
        XCTAssertFalse(try LidAwakeController.parseStatus("System-wide power settings:\n"))
        XCTAssertThrowsError(try LidAwakeController.parseStatus(""))
        XCTAssertThrowsError(try LidAwakeController.parseStatus("System-wide power settings:\n SleepDisabled invalid"))
    }

    @MainActor
    func testToggleUsesAuthorizationAndReadsActualState() async {
        let system = SleepSettingsStub()
        let controller = LidAwakeController(run: { try await system.run($0, $1) })
        await controller.refresh()
        XCTAssertEqual(controller.isEnabled, false)
        await controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, true)
        XCTAssertNil(controller.errorMessage)
        await controller.setEnabled(false)
        XCTAssertEqual(controller.isEnabled, false)
        let scripts = await system.scripts
        XCTAssertEqual(scripts, [
            "do shell script \"/usr/bin/pmset -a disablesleep 1\" with administrator privileges",
            "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges",
        ])
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testCancellationAndFailureKeepActualState() async {
        let system = SleepSettingsStub()
        let controller = LidAwakeController(run: { try await system.run($0, $1) })
        await controller.refresh()
        await system.setFailure(.cancelled)
        await controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertNil(controller.errorMessage)
        await system.setFailure(.failed("Permission denied"))
        await controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(controller.errorMessage, "Permission denied")
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testIgnoredChangeAndUnknownStatusAreReported() async {
        let system = SleepSettingsStub()
        let controller = LidAwakeController(run: { try await system.run($0, $1) })
        await controller.refresh()
        await system.ignoreChanges()
        await controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertNotNil(controller.errorMessage)
        await system.breakStatus()
        await controller.refresh()
        XCTAssertNil(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isBusy)
    }
}

private actor SleepSettingsStub {
    private var enabled = false
    private var failure: LidAwakeError?
    private var ignoresChanges = false
    private var invalidStatus = false
    private(set) var scripts: [String] = []

    func setFailure(_ error: LidAwakeError) { self.failure = error }
    func ignoreChanges() { self.ignoresChanges = true }
    func breakStatus() { self.invalidStatus = true }

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        if executable == "/usr/bin/pmset", arguments == ["-g"] {
            return self.invalidStatus ? "" : "System-wide power settings:\n SleepDisabled \(self.enabled ? 1 : 0)"
        }
        guard executable == "/usr/bin/osascript", arguments.count == 2, arguments[0] == "-e" else {
            throw LidAwakeError.failed("Unexpected command")
        }
        self.scripts.append(arguments[1])
        if let failure { throw failure }
        if !self.ignoresChanges {
            self.enabled = arguments[1] == LidAwakeController.authorizationScript(enabled: true)
        }
        return ""
    }
}
