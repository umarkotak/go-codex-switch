import AppKit
import Foundation

/// One Claude desktop data folder. Each account gets its own folder, started with Electron's `--user-data-dir`.
struct ClaudeDesktopProfile: Sendable, Equatable, Identifiable {
    static let defaultName = "default"

    let name: String
    let dataDirectory: URL
    let isDefault: Bool

    var id: String { self.name }
}

struct ClaudeDesktopProfileStore: Sendable {
    let homeURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    var defaultDataDirectory: URL {
        ClaudeDesktopSessionReader.defaultDataDirectory(homeURL: self.homeURL)
    }

    var profilesDirectory: URL {
        self.homeURL
            .appendingPathComponent(".go-codex-switch", isDirectory: true)
            .appendingPathComponent("claude-profiles", isDirectory: true)
    }

    /// The normal Claude folder (when Claude has been run) followed by extra profiles, sorted by name.
    func listProfiles() -> [ClaudeDesktopProfile] {
        var profiles: [ClaudeDesktopProfile] = []
        if self.hasCookieStore(self.defaultDataDirectory) {
            profiles.append(ClaudeDesktopProfile(
                name: ClaudeDesktopProfile.defaultName,
                dataDirectory: self.defaultDataDirectory,
                isDefault: true))
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: self.profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory, self.hasCookieStore(url) else { continue }
            profiles.append(ClaudeDesktopProfile(name: url.lastPathComponent, dataDirectory: url, isDefault: false))
        }
        return profiles
    }

    /// `account-2`, `account-3`, ... The normal Claude folder counts as the first account.
    func nextProfileName() -> String {
        var index = 2
        while FileManager.default.fileExists(
            atPath: self.profilesDirectory.appendingPathComponent("account-\(index)").path)
        {
            index += 1
        }
        return "account-\(index)"
    }

    func createProfile(named name: String) throws -> ClaudeDesktopProfile {
        let directory = self.profilesDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return ClaudeDesktopProfile(name: name, dataDirectory: directory, isDefault: false)
    }

    private func hasCookieStore(_ dataDirectory: URL) -> Bool {
        ClaudeDesktopSessionReader.cookieStoreURLs(in: dataDirectory)
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum ClaudeDesktopLauncherError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message): "Could not open Claude: \(message)"
        }
    }
}

/// Starts and finds Claude desktop instances. Several instances can run side by side when each uses its own
/// `--user-data-dir`.
struct ClaudeDesktopLauncher: Sendable {
    struct Instance: Equatable, Sendable {
        let pid: Int32
        /// `nil` for the default profile (no `--user-data-dir` argument).
        let profileDirectory: String?
    }

    static let dataDirectoryFlag = "--user-data-dir="

    var applicationURL: URL {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    /// Parses `ps -axo pid=,command=` output into main (non-helper) Claude processes.
    static func parseInstances(psOutput: String) -> [Instance] {
        var instances: [Instance] = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])
            guard command.contains("/Contents/MacOS/Claude"), !command.contains("Helper") else { continue }
            var profile: String?
            if let range = command.range(of: Self.dataDirectoryFlag) {
                var value = String(command[range.upperBound...])
                if let next = value.range(of: " --") { value = String(value[..<next.lowerBound]) }
                profile = value.trimmingCharacters(in: .whitespaces)
            }
            instances.append(Instance(pid: pid, profileDirectory: profile))
        }
        return instances
    }

    func runningInstances() -> [Instance] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Self.parseInstances(psOutput: String(decoding: data, as: UTF8.self))
    }

    static func instance(for profile: ClaudeDesktopProfile, in instances: [Instance]) -> Instance? {
        let target = profile.dataDirectory.standardizedFileURL.path
        return instances.first { instance in
            guard let directory = instance.profileDirectory else { return profile.isDefault }
            return URL(fileURLWithPath: directory).standardizedFileURL.path == target
        }
    }

    /// Brings the profile's window forward when it is already running; otherwise starts a new instance.
    @MainActor
    func open(_ profile: ClaudeDesktopProfile) throws {
        if let running = Self.instance(for: profile, in: self.runningInstances()),
           let app = NSRunningApplication(processIdentifier: running.pid)
        {
            app.activate(options: [.activateAllWindows])
            return
        }
        var arguments = ["-n", "-a", self.applicationURL.path]
        if !profile.isDefault {
            arguments += ["--args", Self.dataDirectoryFlag + profile.dataDirectory.path]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ClaudeDesktopLauncherError.launchFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeDesktopLauncherError.launchFailed(message.isEmpty ? "open exited with an error" : message)
        }
    }
}
