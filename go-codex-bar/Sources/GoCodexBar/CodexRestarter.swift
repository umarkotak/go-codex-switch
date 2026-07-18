import Foundation

enum CodexRestarterError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message): message
        }
    }
}

enum CodexRestarter {
    static func restart() async throws {
        try await Task.detached(priority: .userInitiated) {
            if (try? self.run("/usr/bin/osascript", ["-e", "quit app \"Codex\""])) == nil {
                _ = try? self.run("/usr/bin/pkill", ["-x", "Codex"])
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try self.run("/usr/bin/open", ["-a", "Codex"])
        }.value
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexRestarterError.commandFailed(detail?.isEmpty == false ? detail! : "Command failed: \(executable)")
        }
    }
}
