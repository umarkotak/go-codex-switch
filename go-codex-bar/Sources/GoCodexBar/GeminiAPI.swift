import Darwin
import Foundation
import Security

struct GeminiLocalServer: Sendable {
    enum Kind: Int, Sendable { case app, cli, ide }
    let pid: Int32
    let kind: Kind
    let csrfToken: String?
    let extensionPort: Int?
    let extensionToken: String?
}

struct GeminiAPI: Sendable {
    typealias Command = @Sendable (String, [String], TimeInterval) async throws -> Data
    let command: Command
    let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let environment: [String: String]
    private static let delegate = GeminiLocalSessionDelegate()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    init(
        command: @escaping Command = { try await GeminiCommand.run($0, $1, timeout: $2) },
        load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await GeminiAPI.session.data(for: $0)
        }, environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.command = command
        self.load = load
        self.environment = environment
    }

    func fetch(source: GeminiUsageSource) async throws -> [GeminiAccountSnapshot] {
        let data = try await self.command("/bin/ps", ["-axo", "uid=,pid=,command="], 3)
        let servers = Self.servers(from: String(decoding: data, as: UTF8.self), uid: getuid())
        let kinds: [GeminiLocalServer.Kind] = switch source {
        case .auto: [.app, .cli, .ide]
        case .antigravity: [.app, .ide]
        case .cli: [.cli]
        }
        var lastError: Error = GeminiUsageError.notRunning
        for kind in kinds {
            var accounts: [GeminiAccountSnapshot] = []
            for server in servers where server.kind == kind {
                do {
                    let account = try await self.fetch(server: server)
                    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                        if account.windows.count > accounts[index].windows.count { accounts[index] = account }
                    } else { accounts.append(account) }
                } catch is CancellationError { throw CancellationError() }
                catch { lastError = error }
            }
            if !accounts.isEmpty { return accounts }
            if kind == .cli, let cli = self.cliPath() {
                do { return [try await self.fetchCLI(path: cli)] }
                catch is CancellationError { throw CancellationError() }
                catch { lastError = error }
            }
        }
        throw lastError
    }

    private func fetch(server: GeminiLocalServer) async throws -> GeminiAccountSnapshot {
        var token = server.csrfToken
        if token == nil {
            // New desktop releases pass the CSRF token in the child's environment instead of argv.
            let data = try await self.command("/bin/ps", ["eww", "-p", "\(server.pid)", "-o", "command="], 3)
            token = Self.environmentToken(String(decoding: data, as: UTF8.self))
        }
        guard token != nil || server.kind == .cli else { throw GeminiUsageError.authentication }
        let listeners = try await self.command(
            "/usr/sbin/lsof", ["-nP", "-a", "-p", "\(server.pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"], 3)
        let ports = Self.ports(from: String(decoding: listeners, as: UTF8.self))
        let source = switch server.kind {
        case .app: "Antigravity"
        case .cli: "agy CLI"
        case .ide: "Antigravity IDE"
        }
        var lastError: Error = GeminiUsageError.noQuota
        var endpoints = ports.map { (scheme: "https", port: $0, token: token) }
        if let port = server.extensionPort {
            endpoints.append((scheme: "http", port: port, token: server.extensionToken ?? token))
        }
        let deadline = Date().addingTimeInterval(12)
        for endpoint in endpoints {
            guard Date() < deadline else { break }
            let summary = try? await self.request("RetrieveUserQuotaSummary", endpoint: endpoint)
            try Task.checkCancellation()
            let status = try? await self.request("GetUserStatus", endpoint: endpoint)
            try Task.checkCancellation()
            if let summary, let snapshot = try? GeminiUsageParser.parse(summary, source: source, identity: status) {
                return Self.identify(snapshot, pid: server.pid)
            }
            if let status, let snapshot = try? GeminiUsageParser.parse(status, source: source) {
                return Self.identify(snapshot, pid: server.pid)
            }
            do {
                let configs = try await self.request("GetCommandModelConfigs", endpoint: endpoint)
                return Self.identify(try GeminiUsageParser.parse(configs, source: source, identity: status), pid: server.pid)
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }

    private static func identify(_ snapshot: GeminiAccountSnapshot, pid: Int32) -> GeminiAccountSnapshot {
        GeminiAccountSnapshot(
            id: snapshot.email?.lowercased() ?? "\(snapshot.source)-\(pid)", email: snapshot.email,
            plan: snapshot.plan, source: snapshot.source, windows: snapshot.windows, updatedAt: snapshot.updatedAt)
    }

    private func request(_ method: String, endpoint: (scheme: String, port: Int, token: String?)) async throws -> Data {
        let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let token = endpoint.token { request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        request.httpBody = try JSONSerialization.data(withJSONObject: method == "RetrieveUserQuotaSummary"
            ? ["forceRefresh": true] : ["metadata": ["ideName": "antigravity", "extensionName": "antigravity",
                                                   "ideVersion": "unknown", "locale": "en"]])
        let (data, response) = try await self.load(request)
        guard let http = response as? HTTPURLResponse else { throw GeminiUsageError.noQuota }
        if http.statusCode == 401 || http.statusCode == 403 { throw GeminiUsageError.authentication }
        guard http.statusCode == 200 else { throw GeminiUsageError.server(http.statusCode) }
        guard data.count <= 1_048_576 else { throw GeminiUsageError.outputLimit }
        return data
    }

    func cliPath() -> String? {
        let files = FileManager.default
        if let override = self.environment["ANTIGRAVITY_CLI_PATH"] {
            return files.isExecutableFile(atPath: override) ? override : nil
        }
        let home = files.homeDirectoryForCurrentUser.path
        let paths = (self.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/agy" } +
            ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
             "/Applications/Gemini.app/Contents/Resources/bin/agy", "\(home)/Applications/Gemini.app/Contents/Resources/bin/agy"]
        return paths.first(where: files.isExecutableFile(atPath:))
    }

    private func fetchCLI(path: String) async throws -> GeminiAccountSnapshot {
        var environment = self.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        let version = try await GeminiCommand.run(path, ["--version"], environment: environment)
        guard Self.supportsPrint(String(decoding: version, as: UTF8.self)) else { throw GeminiUsageError.unsupportedCLI }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("go-codex-bar-gemini-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Passive refresh must never open an OAuth browser window.
        for name in ["open", "xdg-open", "browser"] {
            let launcher = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: launcher)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        }
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["BROWSER"] = directory.appendingPathComponent("browser").path
        let report = try await GeminiCommand.run(
            path, ["-p", "/usage", "--output-format", "json"], timeout: 90, environment: environment, directory: directory)
        return try GeminiUsageParser.parse(report, source: "agy CLI", cliReport: true)
    }

    static func supportsPrint(_ version: String) -> Bool {
        guard let range = version.range(of: #"\b\d+\.\d+\.\d+\b"#, options: .regularExpression) else { return false }
        let parts = version[range].split(separator: ".").compactMap { Int($0) }
        return parts.lexicographicallyPrecedes([1, 1, 11]) == false
    }

    static func environmentToken(_ text: String) -> String? {
        self.capture(#"(?:^|\s)ANTIGRAVITY_SERVER_CSRF_TOKEN=([^\s]+)"#, in: text)
    }

    static func servers(from text: String, uid: uid_t) -> [GeminiLocalServer] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, UInt32(fields[0]) == uid, let pid = Int32(fields[1]), pid > 0 else { return nil }
            let command = String(fields[2])
            let executable = command.components(separatedBy: " --").first ?? command
            let lower = executable.lowercased()
            let languageServer = lower.range(of: #"/language[_-]server(?:[_-][a-z0-9]+)*$"#, options: .regularExpression) != nil
            let kind: GeminiLocalServer.Kind
            if languageServer && (lower.contains("antigravity") || command.contains("--app_data_dir antigravity")) {
                kind = lower.contains("antigravity ide") || command.contains("antigravity-ide") ? .ide : .app
            } else if lower.hasSuffix("/agy") || lower.contains("/antigravity-cli/") { kind = .cli }
            else { return nil }
            func flag(_ name: String) -> String? {
                Self.capture("(?:^|\\s)" + name + #"(?:=|\s+)["']?([^\s"']+)"#, in: command)
            }
            let port = flag("--extension_server_port").flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
            return GeminiLocalServer(pid: pid, kind: kind, csrfToken: flag("--csrf_token"), extensionPort: port,
                                     extensionToken: flag("--extension_server_csrf_token"))
        }
    }

    static func ports(from text: String) -> [Int] {
        Array(Set(text.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("n"), let suffix = line.split(separator: ":").last,
                  let port = Int(suffix), (1...65535).contains(port) else { return nil }
            return port
        })).sorted()
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

private final class GeminiLocalSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}
