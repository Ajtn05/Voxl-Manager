import Darwin
import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], input: Data?,
             timeout: TimeInterval, environment: [String: String]) async throws -> ProcessResult
}

extension ProcessRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await run(executable, arguments, input: nil, timeout: timeout, environment: [:])
    }
}

struct ProcessRunner: ProcessRunning {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var requested: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    func run(_ executable: String, _ arguments: [String], input: Data?,
             timeout: TimeInterval, environment: [String: String]) async throws -> ProcessResult {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try execute(executable, arguments, input, timeout, environment, cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(_ executable: String, _ arguments: [String], _ input: Data?,
                         _ timeout: TimeInterval, _ environment: [String: String],
                         _ cancellation: Cancellation) throws -> ProcessResult {
        if cancellation.requested { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        let reads = [out.fileHandleForReading, err.fileHandleForReading]
        let write = stdin.fileHandleForWriting
        let handles = reads + [write, out.fileHandleForWriting, err.fileHandleForWriting, stdin.fileHandleForReading]
        defer { for handle in handles { try? handle.close() } }
        for handle in reads + [write] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else {
                throw ManagerError("Could not configure the process pipes.")
            }
        }
        guard fcntl(write.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ManagerError("Could not configure process input.")
        }
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()
        for handle in [out.fileHandleForWriting, err.fileHandleForWriting, stdin.fileHandleForReading] {
            try? handle.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let bytes = input ?? Data()
        var offset = 0
        var inputOpen = true
        var captured = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 16384)
        let limit = 1_048_576
        func drain() {
            for i in reads.indices {
                // Alternate pipes and check deadlines even if the child floods a stream.
                for _ in 0..<16 {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(reads[i].fileDescriptor, $0.baseAddress, $0.count)
                    }
                    guard count > 0 else { break }
                    let available = min(count, limit - captured[i].count)
                    if available > 0 { captured[i].append(contentsOf: buffer.prefix(available)) }
                }
            }
        }
        while true {
            drain()
            if !process.isRunning {
                drain()
                break
            }
            let cancelled = cancellation.requested
            if cancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.35
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    drain()
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancelled { throw CancellationError() }
                throw ManagerError("\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout)) seconds.")
            }
            if inputOpen {
                if offset < bytes.count {
                    let count = bytes.withUnsafeBytes {
                        Darwin.write(write.fileDescriptor, $0.baseAddress?.advanced(by: offset), min(16384, $0.count - offset))
                    }
                    if count > 0 { offset += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { offset = bytes.count }
                }
                if offset == bytes.count {
                    try? write.close()
                    inputOpen = false
                }
            }
            Thread.sleep(forTimeInterval: 0.015)
        }
        if cancellation.requested { throw CancellationError() }
        return .init(exitCode: process.terminationStatus,
                     stdout: String(decoding: captured[0], as: UTF8.self),
                     stderr: String(decoding: captured[1], as: UTF8.self))
    }
}

enum DiagnosticText {
    static func safe(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"(?i)(https?://[^\s?#]+)\?[^\s]+"#, with: "$1?[redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)((?:token|password|passphrase|authorization|cookie|secret)[^\n]{0,30}[:=]\s*)[^\n]+"#,
                                  with: "$1[redacted]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
