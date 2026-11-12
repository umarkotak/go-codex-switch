import Foundation
import XCTest
@testable import GoCodexBar

final class ClaudeLimitResetTests: XCTestCase {
    private let now = ISO8601DateFormatter.codexDate(from: "2026-11-12T00:00:00Z")!

    private func usage(_ cedarEmber: String) throws -> ClaudeUsageResponse {
        let json = """
        {"five_hour":{"utilization":10,"resets_at":"2026-11-12T03:00:00Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-11-15T00:00:00Z"},
         "cedar_ember": \(cedarEmber)}
        """
        return try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    }

    func testCountsOnlyAvailableGrantsSoonestFirst() throws {
        let response = try self.usage("""
        {"eligible":true,"grants":[
          {"resets_left":2,"resets_total":3,"starts_at":"2026-11-01T00:00:00Z","ends_at":"2026-11-30T00:00:00Z","paused":false},
          {"resets_left":1,"starts_at":null,"ends_at":"2026-11-20T00:00:00Z","paused":false},
          {"resets_left":1,"ends_at":null,"paused":false},
          {"resets_left":1,"ends_at":"2026-11-10T00:00:00Z","paused":false},
          {"resets_left":1,"ends_at":"2026-11-25T00:00:00Z","paused":true},
          {"resets_left":1,"starts_at":"2026-11-20T00:00:00Z","ends_at":"2026-12-01T00:00:00Z","paused":false},
          {"resets_left":1,"ends_at":"not-a-date","paused":false},
          {"resets_left":1,"ends_at":"2026-11-26T00:00:00Z"},
          {"resets_left":5,"resets_total":2,"ends_at":"2026-11-26T00:00:00Z","paused":false}
        ]}
        """)
        let expirations = response.availableResetExpirations(at: self.now)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(
            expirations.map { $0.map { formatter.string(from: $0) } },
            ["2026-11-20T00:00:00Z", "2026-11-30T00:00:00Z", "2026-11-30T00:00:00Z", nil])
        // The quota windows are unaffected.
        XCTAssertEqual(response.fiveHour?.remainingPercent, 90)
    }

    func testIneligibleOversizedAndMalformedBlocksYieldNothingButKeepQuota() throws {
        XCTAssertTrue(try self.usage(#"{"eligible":false,"grants":[{"resets_left":1,"paused":false}]}"#)
            .availableResetExpirations(at: self.now).isEmpty)
        XCTAssertTrue(try self.usage(#"{"eligible":true,"grants":[{"resets_left":51,"paused":false}]}"#)
            .availableResetExpirations(at: self.now).isEmpty)

        let garbage = try self.usage(#"{"eligible":"yes"}"#)
        XCTAssertTrue(garbage.availableResetExpirations(at: self.now).isEmpty)
        XCTAssertEqual(garbage.sevenDay?.remainingPercent, 80)

        let missing = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(#"{"five_hour":null}"#.utf8))
        XCTAssertTrue(missing.availableResetExpirations(at: self.now).isEmpty)
    }

    func testExpiryPassingBetweenRefreshesDropsTheReset() throws {
        let response = try self.usage(#"{"eligible":true,"grants":[{"resets_left":1,"ends_at":"2026-11-13T00:00:00Z","paused":false}]}"#)
        XCTAssertEqual(response.availableResetExpirations(at: self.now).count, 1)
        XCTAssertTrue(response.availableResetExpirations(at: self.now.addingTimeInterval(3 * 86_400)).isEmpty)
    }
}
