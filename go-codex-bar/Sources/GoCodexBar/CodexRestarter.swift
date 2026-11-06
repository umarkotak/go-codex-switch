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

    @MainActor
    static func restart(
        requestQuit: (Bool) -> Void = { force in
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                if force { app.forceTerminate() } else { app.terminate() }
            }
        },
        isRunning: () -> Bool = {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains { !$0.isTerminated }
        },
        launch: () async throws -> Void = {
            try await Task.detached(priority: .userInitiated) {
                try Self.run("/usr/bin/open", ["-n", "-b", bundleIdentifier])
            }.value
        },
        timeout: Duration = .seconds(5),
        beforeLaunch: () async throws -> Void = {}) async throws
    {
        requestQuit(false)
        if try await !self.waitForState(false, isRunning: isRunning, timeout: timeout) {
            requestQuit(true)
            guard try await self.waitForState(false, isRunning: isRunning, timeout: timeout) else {
                throw CodexRestarterError.commandFailed("ChatGPT did not exit. Quit it manually and choose Restart ChatGPT.")
            }
        }

        var preparationError: Error?
        do {
            try await beforeLaunch()
        } catch {
            preparationError = error
        }
        try await launch()
        guard try await self.waitForState(true, isRunning: isRunning, timeout: timeout) else {
            throw CodexRestarterError.commandFailed("ChatGPT did not start after the restart request.")
        }
        if let preparationError { throw preparationError }
    }

    static func syncLocalProjects() async throws {
        try await projectCommand(["_sync-projects-after-quit"])
    }

    static func projectCommand(_ arguments: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let executable = ProcessInfo.processInfo.environment["GO_CODEX_SWITCH_HELPER"]
                ?? Bundle.main.url(forAuxiliaryExecutable: "go-codex-switch")?.path
            guard let executable else {
                throw CodexRestarterError.commandFailed("The local project sync helper is missing. Rebuild Go Codex Bar.")
            }
            try Self.run(executable, arguments)
        }.value
    }

    @MainActor
    private static func waitForState(_ expected: Bool, isRunning: () -> Bool, timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isRunning() != expected {
            guard ContinuousClock.now < deadline else { return false }
            // Yield to the main run loop so AppKit's process state can update.
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexRestarterError.commandFailed(detail?.isEmpty == false ? detail! : "Command failed: \(executable)")
        }
    }
}
