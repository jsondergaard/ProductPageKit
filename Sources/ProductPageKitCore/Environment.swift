public import Foundation

/// Variables from the process environment over those in the repository's
/// `.env`, so a value exported in the shell wins over the file.
public struct Environment: Sendable {
    public let values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    /// The process environment over `.env` at `root`, when it exists.
    public static func load(root: URL, process: [String: String] = ProcessInfo.processInfo.environment) throws -> Environment {
        let file = root.appending(path: ".env")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Environment(values: process)
        }
        let parsed = parse(try String(contentsOf: file, encoding: .utf8))
        return Environment(values: parsed.merging(process) { _, real in real })
    }

    /// `KEY=VALUE` lines. Blank lines, comments and lines without `=` are
    /// skipped, an `export ` prefix is dropped, and one pair of matching quotes
    /// around a value is removed.
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    public subscript(name: String) -> String? {
        guard let value = values[name], !value.isEmpty else { return nil }
        return value
    }
}
