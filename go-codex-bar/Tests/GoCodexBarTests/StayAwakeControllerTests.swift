import Foundation
import IOKit.pwr_mgt
import XCTest
@testable import GoCodexBar

final class StayAwakeControllerTests: XCTestCase {
    func testStayAwakeLifecycle() async throws {
        try await MainActor.run {
            let suiteName = "GoCodexBarTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var controller: StayAwakeController? = StayAwakeController(defaults: defaults)
            let initialCount = try self.assertionCount()
            XCTAssertFalse(try XCTUnwrap(controller).isEnabled)

            controller?.setEnabled(true)
            XCTAssertTrue(try XCTUnwrap(controller).isEnabled)
            XCTAssertNil(controller?.errorMessage)
            XCTAssertTrue(defaults.bool(forKey: "stayAwake"))
            XCTAssertEqual(try self.assertionCount(), initialCount + 1)

            controller?.setEnabled(true)
            XCTAssertEqual(try self.assertionCount(), initialCount + 1)
            controller = nil
            XCTAssertEqual(try self.assertionCount(), initialCount)

            // A new app instance restores the saved preference without opening its panel.
            controller = StayAwakeController(defaults: defaults)
            XCTAssertTrue(try XCTUnwrap(controller).isEnabled)
            XCTAssertEqual(try self.assertionCount(), initialCount + 1)
            controller?.setEnabled(false)
            XCTAssertFalse(try XCTUnwrap(controller).isEnabled)
            XCTAssertFalse(defaults.bool(forKey: "stayAwake"))
            XCTAssertEqual(try self.assertionCount(), initialCount)
            controller?.setEnabled(false)
            XCTAssertEqual(try self.assertionCount(), initialCount)
        }
    }

    private func assertionCount() throws -> Int {
        var assertions: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&assertions)
        XCTAssertEqual(result, kIOReturnSuccess)
        let byProcess = try XCTUnwrap(assertions).takeRetainedValue() as NSDictionary
        let current = byProcess[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
        return current.filter {
            $0[kIOPMAssertionNameKey] as? String == "Go Codex Bar: Stay Awake"
                && $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleDisplaySleep
                && $0[kIOPMAssertionLevelKey] as? Int == kIOPMAssertionLevelOn
        }.count
    }
}
