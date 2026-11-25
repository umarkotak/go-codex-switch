import Darwin
import Foundation
import XCTest
@testable import GoCodexBar

final class GeminiUsageTests: XCTestCase {
    private static let summary = Data(#"""
    {"response":{"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","remainingFraction":0.94,"resetTime":"2026-12-01T12:00:00Z"},
        {"bucketId":"gemini-5h","remainingFraction":0.82,"description":"Resets in 2 hours"}]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","remaining":{"remainingFraction":1}},
        {"bucketId":"3p-5h","remaining":{"case":"remainingFraction","value":0}}]}
    ]}}
    """#.utf8)
    private static let identity = Data(#"""
    {"userStatus":{"email":"User@example.com","userTier":{"name":"Google AI Pro"}}}
    """#.utf8)

    func testParsesLiveProtocolShapesAndKeepsFamilyCadencesSeparate() throws {
        let result = try GeminiUsageParser.parse(Self.summary, source: "Antigravity", identity: Self.identity)
        XCTAssertEqual(result.email, "User@example.com")
        XCTAssertEqual(result.id, "user@example.com")
        XCTAssertEqual(result.plan, "Google AI Pro")
        XCTAssertEqual(result.windows.map(\.title), ["Gemini Session", "Gemini Weekly", "Claude/GPT Session", "Claude/GPT Weekly"])
        XCTAssertEqual(result.windows.map(\.remainingPercent), [82, 94, 0, 100])
        XCTAssertNotNil(result.windows[1].resetDate)
        XCTAssertEqual(result.windows[0].resetDescription, "Resets in 2 hours")
    }

    func testUnknownDisabledAndInvalidFractionsNeverBecomeUsage() throws {
        let data = Data(#"""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-weekly","remainingFraction":0.5},
          {"bucketId":"unknown","resetTime":"2026-12-01T12:00:00Z"},
          {"bucketId":"disabled","remainingFraction":0,"disabled":true},
          {"bucketId":"boolean","remainingFraction":true},
          {"bucketId":"negative","remainingFraction":-0.1},
          {"bucketId":"too-high","remainingFraction":1.1}
        ]}]}
        """#.utf8)
        let windows = try GeminiUsageParser.parse(data, source: "Antigravity").windows
        XCTAssertEqual(windows.filter { $0.remainingPercent != nil }.map(\.remainingPercent), [50])
        XCTAssertEqual(windows.filter { $0.remainingPercent == nil }.count, 5)
        let unavailable = Data(#"{"groups":[{"buckets":[{"bucketId":"weekly","remainingFraction":0,"disabled":true}]}]}"#.utf8)
        XCTAssertThrowsError(try GeminiUsageParser.parse(unavailable, source: "Antigravity"))
    }

    func testStarterWeeklyOnlyDoesNotInventSessionQuota() throws {
        let data = Data(#"{"summary":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","remainingFraction":1}]}]}}"#.utf8)
        let windows = try GeminiUsageParser.parse(data, source: "Antigravity").windows
        XCTAssertEqual(windows.map(\.title), ["Gemini Weekly"])
        XCTAssertEqual(windows.first?.remainingPercent, 100)
    }

    func testLegacyQuotaChoosesMostConstrainedModelAndKeepsItsReset() throws {
        let data = Data(#"""
        {"userStatus":{"email":"legacy@example.com","cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini Pro","modelOrAlias":{"model":"gemini-pro"},"quotaInfo":{"remainingFraction":0.7}},
          {"label":"Gemini Flash","modelOrAlias":{"model":"gemini-flash"},"quotaInfo":{"remainingFraction":0.3,"resetTime":"1800000000"}},
          {"label":"Gemini Image","modelOrAlias":{"model":"gemini-image"},"quotaInfo":{"remainingFraction":0}},
          {"label":"Claude","modelOrAlias":{"model":"claude"},"quotaInfo":{"resetTime":"1800000000"}}
        ]}}}
        """#.utf8)
        let result = try GeminiUsageParser.parse(data, source: "Antigravity IDE")
        XCTAssertEqual(result.windows.first?.remainingPercent, 30)
        XCTAssertEqual(result.windows.first?.resetDate, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(result.windows.last?.remainingPercent)
    }

    func testCLIRequiresSuccessfulUsageCommandAndSupportsSnakeCase() throws {
        let payload = #"{"groups":[{"display_name":"Gemini Models","buckets":[{"bucket_id":"gemini-weekly","remaining_fraction":0.25}]}]}"#
        let data = Data("{\"status\":\"SUCCESS\",\"command\":{\"name\":\"usage\",\"data\":\(payload)}}".utf8)
        let result = try GeminiUsageParser.parse(data, source: "agy CLI", cliReport: true)
        XCTAssertNil(result.email)
        XCTAssertEqual(result.title, "agy CLI")
        XCTAssertEqual(result.windows.first?.remainingPercent, 25)
        for invalid in ["ERROR", "usage-prompt"] {
            let changed = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: invalid == "ERROR" ? "SUCCESS" : "usage", with: invalid)
            XCTAssertThrowsError(try GeminiUsageParser.parse(Data(changed.utf8), source: "agy CLI", cliReport: true))
        }
        XCTAssertThrowsError(try GeminiUsageParser.parse(Data(#"{"code":7,"groups":[]}"#.utf8), source: "Antigravity"))
    }

    func testDetectionScopesProcessesToCurrentUserAndRecognizedExecutables() {
        let servers = GeminiAPI.servers(from: """
        501 42 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone
        501 43 /Applications/Antigravity IDE.app/bin/language_server_macos_arm --csrf_token=ide-token --extension_server_port 1234
        501 44 /usr/local/bin/agy --version
        502 45 /Applications/Antigravity.app/bin/language_server --csrf_token other-user
        501 46 /usr/bin/editor --comment /antigravity/language_server
        501 47 /usr/bin/other --comment agy
        """, uid: 501)
        XCTAssertEqual(servers.map(\.pid), [42, 43, 44])
        XCTAssertEqual(servers.map(\.kind), [.app, .ide, .cli])
        XCTAssertNil(servers[0].csrfToken)
        XCTAssertEqual(servers[1].csrfToken, "ide-token")
        XCTAssertEqual(servers[1].extensionPort, 1234)
        XCTAssertEqual(GeminiAPI.environmentToken("binary PATH=/bin ANTIGRAVITY_SERVER_CSRF_TOKEN=env-token OTHER=x"), "env-token")
        XCTAssertNil(GeminiAPI.environmentToken("binary OTHER_ANTIGRAVITY_SERVER_CSRF_TOKEN=wrong"))
        XCTAssertEqual(GeminiAPI.ports(from: "p42\nf7\nn127.0.0.1:1234\nn[::1]:1234\nn*:4321\nn*:0\nn*:99999"), [1234, 4321])
    }

    func testAutoReadsEnvironmentTokenAndCombinesQuotaWithSameServerIdentity() async throws {
        let recorder = RequestRecorder()
        let uid = getuid()
        let api = GeminiAPI(command: { executable, arguments, _ in
            if executable == "/usr/sbin/lsof" { return Data("p42\nn127.0.0.1:1234".utf8) }
            if arguments.first == "eww" { return Data("server ANTIGRAVITY_SERVER_CSRF_TOKEN=local-token".utf8) }
            return Data("\(uid) 42 /Applications/Antigravity.app/bin/language_server --standalone".utf8)
        }, load: { request in
            await recorder.append(request)
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "local-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            let summary = request.url!.lastPathComponent == "RetrieveUserQuotaSummary"
            if summary {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Bool]
                XCTAssertEqual(body, ["forceRefresh": true])
            }
            return (summary ? Self.summary : Self.identity,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, environment: ["ANTIGRAVITY_CLI_PATH": ""])
        let result = try await api.fetch(source: .auto)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.email, "User@example.com")
        let paths = await recorder.paths()
        XCTAssertEqual(paths, ["RetrieveUserQuotaSummary", "GetUserStatus"])
    }

    func testAutoFallsThroughToIDEWhenAppQuotaIsUnavailable() async throws {
        let uid = getuid()
        let api = GeminiAPI(command: { executable, arguments, _ in
            if executable == "/usr/sbin/lsof" {
                return Data("n127.0.0.1:\(arguments.contains("42") ? 1234 : 4321)".utf8)
            }
            return Data("""
            \(uid) 42 /Applications/Antigravity.app/bin/language_server --csrf_token app
            \(uid) 43 /Applications/Antigravity IDE.app/bin/language_server --csrf_token ide
            """.utf8)
        }, load: { request in
            let success = request.url?.port == 4321
            return (success ? Self.summary : Data(), HTTPURLResponse(
                url: request.url!, statusCode: success ? 200 : 404, httpVersion: nil, headerFields: nil)!)
        }, environment: ["ANTIGRAVITY_CLI_PATH": ""])
        let result = try await api.fetch(source: .auto)
        XCTAssertEqual(result.first?.source, "Antigravity IDE")
        XCTAssertNil(result.first?.email)
        XCTAssertEqual(result.first?.id, "Antigravity IDE-43")
    }

    func testExplicitCLISourceDoesNotUseDesktopAccount() async {
        let uid = getuid()
        let api = GeminiAPI(command: { _, _, _ in
            Data("\(uid) 42 /Applications/Antigravity.app/bin/language_server --csrf_token app".utf8)
        }, load: { _ in
            XCTFail("CLI-only mode must not probe the desktop")
            throw GeminiUsageError.noQuota
        }, environment: ["ANTIGRAVITY_CLI_PATH": ""])
        do { _ = try await api.fetch(source: .cli); XCTFail("Expected unavailable") }
        catch { XCTAssertTrue(error is GeminiUsageError) }
        XCTAssertNil(api.cliPath())
    }

    func testCLIVersionGate() {
        for version in ["agy 1.1.11", "1.2.2", "agy 2.0.0"] { XCTAssertTrue(GeminiAPI.supportsPrint(version)) }
        for version in ["1.1.10", "1.0.99", "unknown", "0.99.99"] { XCTAssertFalse(GeminiAPI.supportsPrint(version)) }
    }

    func testCommandTimeoutAndOutputLimit() async throws {
        do {
            _ = try await GeminiCommand.run("/bin/sleep", ["10"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch GeminiUsageError.timeout {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await GeminiCommand.run("/usr/bin/head", ["-c", "1048577", "/dev/zero"])
            XCTFail("Expected output limit")
        } catch GeminiUsageError.outputLimit {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCommandCancellationStopsPromptly() async throws {
        let task = Task { try await GeminiCommand.run("/bin/sleep", ["10"], timeout: 20) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let start = Date()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testPrintFallbackUsesUsageOnlyAndBlocksBrowserLaunchers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agy")
        let script = #"""
        #!/bin/sh
        test "$AGY_CLI_DISABLE_AUTO_UPDATE" = true || exit 2
        if test "$1" = --version; then
          echo 'agy 1.2.11'
          exit 0
        fi
        test "$1" = -p && test "$2" = /usage && test "$3" = --output-format && test "$4" = json || exit 3
        test -x "$BROWSER" || exit 4
        if "$BROWSER"; then exit 5; fi
        if open 'https://example.invalid'; then exit 6; fi
        if xdg-open 'https://example.invalid'; then exit 7; fi
        echo '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","remainingFraction":0.5}]}]}}}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let api = GeminiAPI(command: { _, _, _ in Data() }, environment: [
            "ANTIGRAVITY_CLI_PATH": executable.path,
            "PATH": "/usr/bin:/bin",
        ])
        let accounts = try await api.fetch(source: .auto)
        XCTAssertEqual(accounts.first?.title, "agy CLI")
        XCTAssertEqual(accounts.first?.windows.first?.remainingPercent, 50)
        XCTAssertNil(accounts.first?.email)
    }

    func testLiveDetectionWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["GO_CODEX_BAR_TEST_LIVE_GEMINI"] == "1" else {
            throw XCTSkip("Opt-in local Antigravity integration check")
        }
        let accounts = try await GeminiAPI().fetch(source: .auto)
        XCTAssertFalse(accounts.isEmpty)
        XCTAssertNotNil(accounts.first?.email)
        XCTAssertTrue(accounts.first?.windows.contains { $0.remainingPercent != nil } == true)
    }
}

private actor RequestRecorder {
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { self.requests.append(request) }
    func paths() -> [String] { self.requests.map { $0.url!.lastPathComponent } }
}
