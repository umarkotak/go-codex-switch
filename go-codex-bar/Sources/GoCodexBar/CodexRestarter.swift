import AppKit
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
    static let bundleIdentifier = "com.openai.codex"

    static func restart(
        run: @escaping @Sendable (String, [String]) throws -> Void = { try Self.run($0, $1) },
        forceQuit: @escaping @Sendable () throws -> Void = { try Self.forceQuit() }) async throws
    {
        try await Task.detached(priority: .userInitiated) {
            if (try? run("/usr/bin/osascript", ["-e", "quit app id \"\(self.bundleIdentifier)\""])) == nil {
                try forceQuit()
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try run("/usr/bin/open", ["-b", self.bundleIdentifier])
        }.value
    }

    private static func forceQuit() throws {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleIdentifier) {
            guard app.isTerminated || app.forceTerminate() else {
                throw CodexRestarterError.commandFailed("Could not quit ChatGPT. Quit it manually and try again.")
            }
        }
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
