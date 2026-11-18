import Foundation

/// Claude Code on macOS keeps its OAuth login in the login Keychain as a generic password named
/// `Claude Code-credentials` (plus a suffixed name per `CLAUDE_CONFIG_DIR`). The value is the same JSON as
/// `~/.claude/.credentials.json`. Claude Code writes these items with `/usr/bin/security`, so reading them
/// through the same tool normally needs no Keychain prompt.
struct ClaudeCodeKeychain: Sendable {
    static let servicePrefix = "Claude Code-credentials"

    struct Item: Sendable, Equatable {
        let service: String
        let account: String?

        var isDefault: Bool { self.service == ClaudeCodeKeychain.servicePrefix }
    }

    struct CommandResult: Sendable {
        let status: Int32
        let output: Data
    }

    typealias Runner = @Sendable (_ arguments: [String], _ input: Data?) -> CommandResult

    let run: Runner

    init(run: @escaping Runner = ClaudeCodeKeychain.runSecurity) {
        self.run = run
    }

    /// Every Claude Code credential item, default first.
    func items() -> [Item] {
        let result = self.run(["dump-keychain"], nil)
        guard result.status == 0 else { return [] }
        return Self.parseItems(String(decoding: result.output, as: UTF8.self))
    }

    func read(_ item: Item) -> Data? {
        var arguments = ["find-generic-password", "-s", item.service]
        if let account = item.account, !account.isEmpty {
            arguments += ["-a", account]
        }
        arguments.append("-w")
        let result = self.run(arguments, nil)
        guard result.status == 0 else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // `security -w` prints non-printable values as hex.
        if !text.hasPrefix("{"), let decoded = Self.hexDecoded(text) { return decoded }
        return Data(text.utf8)
    }

    /// Replaces the item's value, creating it when missing. The value goes through stdin, not the command line.
    func write(_ data: Data, to item: Item) throws {
        let account = item.account ?? NSUserName()
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \(Self.quoted(account)) -s \(Self.quoted(item.service)) -X \(hex)\n"
        let result = self.run(["-i"], Data(command.utf8))
        guard result.status == 0 else {
            throw ClaudeAuthStoreError.keychainWriteFailed(result.status)
        }
    }

    static func parseItems(_ dump: String) -> [Item] {
        var items: [Item] = []
        var service: String?
        var account: String?
        var isGenericPassword = false

        func flush() {
            if isGenericPassword, let service, service.hasPrefix(Self.servicePrefix) {
                let item = Item(service: service, account: account)
                if !items.contains(item) { items.append(item) }
            }
            service = nil
            account = nil
            isGenericPassword = false
        }

        for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("keychain:") {
                flush()
            } else if line.hasPrefix("class:") {
                isGenericPassword = line.contains("\"genp\"")
            } else if let value = Self.blobAttribute("svce", in: line) {
                service = value
            } else if let value = Self.blobAttribute("acct", in: line) {
                account = value
            }
        }
        flush()
        return items.sorted { lhs, rhs in
            lhs.isDefault != rhs.isDefault ? lhs.isDefault : lhs.service < rhs.service
        }
    }

    /// `"svce"<blob>="Claude Code-credentials"` -> `Claude Code-credentials`. Hex-only blobs are skipped.
    private static func blobAttribute(_ name: String, in line: String) -> String? {
        let prefix = "\"\(name)\"<blob>=\""
        guard line.hasPrefix(prefix), line.hasSuffix("\""), line.count > prefix.count else { return nil }
        return String(line.dropFirst(prefix.count).dropLast())
    }

    private static func hexDecoded(_ text: String) -> Data? {
        let hex = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @Sendable
    static func runSecurity(arguments: [String], input: Data?) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: Data())
        }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: data)
    }
}
