import Foundation

/// An exclusive lock on a file, held until `release()` or the process ends.
///
/// `flock` belongs to the open file, so a run that is killed outright frees it
/// with its descriptors and there is no stale lock to take over. The holder's
/// pid is written inside only to name it to the next run.
final class Lock: Sendable {
    private let descriptor: Int32

    init(_ url: URL, purpose: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw RunnerError.lock(url.path, "could not open it: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let holder = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            close(descriptor)
            throw RunnerError.busy(purpose, holder: holder.flatMap(Int32.init))
        }
        ftruncate(descriptor, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        self.descriptor = descriptor
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
