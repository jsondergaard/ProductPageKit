public import Foundation

public enum Shell {
    /// Runs `command` with `zsh -c` in `directory` and returns what it printed.
    /// A non-zero exit throws with whatever it wrote to stderr.
    public static func run(_ command: String, in directory: URL) async throws -> Data {
        try await run("/bin/zsh", ["-c", command], in: directory, describedAs: command)
    }

    /// Runs `executable` with `arguments` and returns what it printed to
    /// stdout. With `log`, stdout and stderr both go to that file instead and
    /// nothing is returned; a failure then quotes the log's errors.
    ///
    /// Cancelling the task terminates the process.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        log: URL? = nil,
        describedAs description: String? = nil
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let output = Pipe()
        let errors = Pipe()
        if let log {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = output
            process.standardError = errors
        }
        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()
        return try await withTaskCancellationHandler {
            var data = Data()
            var stderr = ""
            if log == nil {
                // Both pipes are drained at once: a command that fills one
                // blocks until it is read.
                async let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
                data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
                stderr = String(decoding: await errorData, as: UTF8.self)
            }
            var status: Int32 = 0
            for await code in exited { status = code }
            try Task.checkCancellation()
            guard status == 0 else {
                throw ShellError(command: description ?? ([executable] + arguments).joined(separator: " "),
                                 status: status, stderr: stderr, log: log)
            }
            return data
        } onCancel: {
            process.terminate()
        }
    }
}

public struct ShellError: Error, CustomStringConvertible {
    public let command: String
    public let status: Int32
    public let stderr: String
    /// Where the output went, when it went to a file.
    public let log: URL?

    public var description: String {
        var text = "`\(command)` exited with \(status)"
        if !stderr.isEmpty { text += ":\n\(stderr)" }
        if let log {
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
            let errors = lines.filter { $0.contains("error:") }
            let quoted = (errors.isEmpty ? lines.suffix(20) : errors.prefix(20)).joined(separator: "\n")
            if !quoted.isEmpty { text += ":\n\(quoted)" }
            text += "\nThe full output is in \(log.path)"
        }
        return text
    }
}
