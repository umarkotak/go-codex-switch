import Darwin
import Foundation

/// Runs only read-only discovery commands and the CLI's structured usage report.
enum GeminiCommand {
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 3,
        environment: [String: String]? = nil, directory: URL? = nil) async throws -> Data
    {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw GeminiUsageError.commandFailed }
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        // Foundation launches children in their own process group on macOS. Never signal our own group.
        let group = getpgid(process.processIdentifier)
        func stop(_ signal: Int32) {
            if group == process.processIdentifier && group != getpgrp() { kill(-group, signal) }
            else if process.isRunning { kill(process.processIdentifier, signal) }
        }
        defer { stop(SIGKILL) }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func drain() throws {
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= 1_048_576 else { throw GeminiUsageError.outputLimit }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else if errno != EINTR { throw GeminiUsageError.commandFailed }
            }
        }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw GeminiUsageError.timeout }
                try drain()
                try await Task.sleep(for: .milliseconds(50))
            }
            try drain()
        } catch {
            stop(SIGTERM)
            // Let the child exit before its temporary directory is removed.
            try? await Task.sleep(for: .milliseconds(100))
            stop(SIGKILL)
            throw error
        }
        guard process.terminationStatus == 0 else { throw GeminiUsageError.commandFailed }
        return data
    }
}
