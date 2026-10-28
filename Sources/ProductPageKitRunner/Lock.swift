import Foundation

/// An exclusive lock on a file, held until `release()` or the process ends.
///
/// `flock` belongs to the open file, so a run that is killed outright frees it
/// with its descriptors and there is no stale lock to take over. The holder's
/// pid is written inside only to name it to the next run.
final class Lock: Sendable {
    private let descriptor: Int32

    /// Takes the lock, or throws `RunnerError.busy` while another run holds it.
    init(_ url: URL, purpose: String) throws {
        guard let descriptor = try Self.take(url) else { throw RunnerError.busy(purpose, holder: Self.holder(url)) }
        self.descriptor = descriptor
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Takes the lock once another run releases it, calling `waiting` with
    /// the holder's pid the first time it finds the lock held.
    static func waiting(for url: URL, poll: Duration = .seconds(2),
                        _ waiting: @Sendable (Int32?) -> Void) async throws -> Lock {
        var announced = false
        while true {
            if let descriptor = try take(url) { return Lock(descriptor: descriptor) }
            if !announced {
                waiting(holder(url))
                announced = true
            }
            try await Task.sleep(for: poll)
        }
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// The locked file's descriptor, or nil while another run holds it.
    private static func take(_ url: URL) throws -> Int32? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw RunnerError.lock(url.path, "could not open it: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        ftruncate(descriptor, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        return descriptor
    }

    private static func holder(_ url: URL) -> Int32? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
