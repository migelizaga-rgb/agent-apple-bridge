import Darwin
import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private final class BoundedData: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private(set) var exceeded = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(limit - storage.count, 0)
        if remaining > 0 { storage.append(data.prefix(remaining)) }
        if data.count > remaining { exceeded = true }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum ProcessRunner {
    private static func failure(_ result: ProcessResult) -> BridgeError {
        let raw = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = raw.lowercased()
        if ["not authorized", "not permitted", "permission", "automation", "full disk access", "tcc", "-1743"]
            .contains(where: message.contains) {
            return BridgeError("permission_required", "Required macOS privacy permission is unavailable")
        }
        if ["unsupported", "unknown command", "unrecognized option", "no such option"]
            .contains(where: message.contains) {
            return BridgeError("unsupported_action", "The installed Apple integration does not support this action")
        }
        return BridgeError("command_failed", raw.isEmpty ? "Apple bridge command exited \(result.status)" : raw)
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60,
        outputLimit: Int = 8 * 1024 * 1024
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutData = BoundedData(limit: outputLimit)
        let stderrData = BoundedData(limit: min(outputLimit, 1024 * 1024))
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutData.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrData.append(handle.availableData)
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw BridgeError("command_timeout", "Apple bridge command exceeded \(Int(timeout)) seconds")
        }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutData.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrData.append(stderr.fileHandleForReading.readDataToEndOfFile())
        if stdoutData.exceeded || stderrData.exceeded {
            throw BridgeError("command_output_too_large", "Apple bridge command exceeded its output limit")
        }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: stdoutData.snapshot(),
            stderr: stderrData.snapshot()
        )
    }

    static func json(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) throws -> Any {
        let result = try run(executable, arguments, environment: environment, timeout: timeout)
        guard result.status == 0 else {
            throw failure(result)
        }
        guard !result.stdout.isEmpty else { return [:] }
        do {
            return try JSONSerialization.jsonObject(with: result.stdout)
        } catch {
            throw BridgeError("invalid_command_output", "command returned non-JSON output")
        }
    }

    static func jsonRecords(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) throws -> [Any] {
        let result = try run(executable, arguments, environment: environment, timeout: timeout)
        guard result.status == 0 else { throw failure(result) }
        guard !result.stdout.isEmpty else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: result.stdout) {
            if let rows = object as? [Any] { return rows }
            return [object]
        }
        guard let text = String(data: result.stdout, encoding: .utf8) else {
            throw BridgeError("invalid_command_output", "command returned non-UTF-8 output")
        }
        var rows: [Any] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) else {
                throw BridgeError("invalid_command_output", "command returned invalid JSON lines")
            }
            rows.append(row)
        }
        return rows
    }
}
