import Combine
import Foundation

@MainActor
final class LidAwakeController: ObservableObject {
    @Published private(set) var isEnabled: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private let run: @Sendable (String, [String]) async throws -> String

    init(run: @escaping @Sendable (String, [String]) async throws -> String = {
        try await LidAwakeController.runCommand($0, $1)
    }) {
        self.run = run
    }

    func refresh() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            self.isEnabled = try Self.parseStatus(await self.run("/usr/bin/pmset", ["-g"]))
            self.errorMessage = nil
        } catch {
            self.isEnabled = nil
            self.errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !self.isBusy, let current = self.isEnabled, enabled != current else { return }
        self.isBusy = true
        self.errorMessage = nil
        defer { self.isBusy = false }

        var cancelled = false
        do {
            // Only fixed commands reach the privileged shell; never interpolate user input.
            _ = try await self.run("/usr/bin/osascript", ["-e", Self.authorizationScript(enabled: enabled)])
        } catch {
            cancelled = (error as? LidAwakeError) == .cancelled
            if !cancelled {
                self.errorMessage = error.localizedDescription
            }
        }

        do {
            let actual = try Self.parseStatus(await self.run("/usr/bin/pmset", ["-g"]))
            self.isEnabled = actual
            if actual != enabled, !cancelled, self.errorMessage == nil {
                self.errorMessage = "macOS did not apply Lid Awake. The toggle shows the current system setting."
            }
        } catch {
            self.isEnabled = nil
            self.errorMessage = "Could not verify Lid Awake. \(error.localizedDescription)"
        }
    }

    nonisolated static func authorizationScript(enabled: Bool) -> String {
        "do shell script \"/usr/bin/pmset -a disablesleep \(enabled ? 1 : 0)\" with administrator privileges"
    }

    nonisolated static func parseStatus(_ output: String) throws -> Bool {
        guard output.contains("System-wide power settings:") else {
            throw LidAwakeError.failed("Could not read macOS sleep settings.")
        }
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.first == "SleepDisabled" {
                guard fields.count == 2, fields[1] == "0" || fields[1] == "1" else {
                    throw LidAwakeError.failed("macOS returned an unrecognized sleep setting.")
                }
                return fields[1] == "1"
            }
        }
        // macOS omits SleepDisabled when no override has been set.
        return false
    }

    nonisolated private static func runCommand(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                if executable == "/usr/bin/osascript", output.contains("(-128)") {
                    throw LidAwakeError.cancelled
                }
                throw LidAwakeError.failed(output.isEmpty ? "Could not change macOS sleep settings." : output)
            }
            return output
        }.value
    }
}

enum LidAwakeError: LocalizedError, Equatable {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Authorization cancelled."
        case let .failed(message): message
        }
    }
}
