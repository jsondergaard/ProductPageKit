public import Foundation

public enum Repository {
    /// The nearest directory at or above `start` that holds `.git`, a folder
    /// in a clone and a file in a worktree. Config paths are relative to it.
    public static func root(from start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> URL {
        var directory = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { throw RepositoryError.noRoot(start.path) }
            directory = parent
        }
    }
}

public enum RepositoryError: Error, CustomStringConvertible {
    case noRoot(String)

    public var description: String {
        switch self {
        case .noRoot(let path): "No git repository at or above \(path). Run from inside the app's repository."
        }
    }
}
