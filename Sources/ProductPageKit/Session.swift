import ArgumentParser
public import Foundation
public import ProductPageKitASC
public import ProductPageKitCore

/// Where commands print and ask: the terminal in use, a recording in tests.
public protocol Console: Sendable {
    func print(_ line: String)
    /// A line typed by the person running the command, or nil at end of input.
    func readLine(prompt: String) -> String?
    /// Whether someone is there to answer: false in CI and pipes.
    var isInteractive: Bool { get }
}

public struct TerminalConsole: Console {
    public init() {}

    /// Flushed at once, so a long-running command such as `review` shows its
    /// address even when its output is a pipe.
    public func print(_ line: String) {
        Swift.print(line)
        fflush(stdout)
    }

    public func readLine(prompt: String) -> String? {
        Swift.print(prompt, terminator: "")
        fflush(stdout)
        return Swift.readLine()
    }

    public var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }
}

/// A command stopped on purpose, with the reason.
public struct Stopped: Error, CustomStringConvertible {
    public let description: String
}

/// What every command runs against: the project, the repository it lives in,
/// the environment, where to print, and how to reach App Store Connect.
public struct Session: Sendable {
    public let project: Project
    public let root: URL
    public let environment: Environment
    public let console: any Console
    /// Where captures and builds go, outside the repository.
    public let cache: Cache
    let connect: @Sendable () throws -> AppStoreConnect

    @TaskLocal static var current: Session?

    /// The repository around the working directory, its `.env`, the terminal,
    /// and the API key the environment names.
    public init(project: Project) throws {
        let root = try Repository.root()
        let environment = try Environment.load(root: root)
        self.init(project: project, root: root, environment: environment, console: TerminalConsole(),
                  cache: Cache(bundleID: project.bundleID)) {
            AppStoreConnect(credentials: try Credentials(environment: environment))
        }
    }

    public init(project: Project, root: URL, environment: Environment, console: any Console, cache: Cache,
                connect: @escaping @Sendable () throws -> AppStoreConnect) {
        self.project = project
        self.root = root
        self.environment = environment
        self.console = console
        self.cache = cache
        self.connect = connect
    }

    static func get() throws -> Session {
        guard let current else { throw Stopped(description: "Run through ProductPageKit.main(project).") }
        return current
    }

    /// Stops when the configuration itself is wrong.
    func checkProject() throws {
        let problems = project.problems()
        guard problems.isEmpty else {
            throw Stopped(description: "The project configuration has problems:\n" + problems.map { "  \($0)" }.joined(separator: "\n"))
        }
    }

    func copy() throws -> StoreCopy { try StoreCopy.load(project, root: root) }

    /// The platforms a `--platforms` flag names, or every one.
    func platforms(_ flag: String) throws -> [Platform] {
        try selection(flag, from: project.platforms, name: \.id, kind: "platform")
    }

    /// The locales a `--locales` flag names, or every one.
    func locales(_ flag: String) throws -> [StoreLocale] {
        try selection(flag, from: project.locales, name: \.code, kind: "locale")
    }

    /// The custom pages a `--pages` flag names, or every one.
    func pages(_ flag: String) throws -> [CustomPage] {
        try selection(flag, from: project.customPages, name: \.key, kind: "custom page")
    }

    /// The experiments an `--experiments` flag names, or every one.
    func experiments(_ flag: String) throws -> [Experiment] {
        try selection(flag, from: project.experiments, name: \.key, kind: "experiment")
    }

    /// The App Store platforms a flag names, or every configured one.
    func storePlatforms(_ flag: String) throws -> [StorePlatform] {
        try selection(flag, from: project.storePlatforms, name: \.key, kind: "platform")
    }

    /// The App Store platforms builds are archived for that a flag names, or
    /// every one.
    func buildPlatforms(_ flag: String) throws -> [StorePlatform] {
        try selection(flag, from: project.buildPlatforms, name: \.key, kind: "platform")
    }

    func motionTheme() throws -> any MotionTheme {
        guard let theme = project.videos else { throw Stopped(description: "The project has no videos (Project.videos).") }
        return theme
    }

    func warn(_ message: String) { console.print("warning: \(message)") }

    /// Concurrent changes in flight at once: enough to keep an upload link
    /// busy through each change's API calls, and few enough not to crowd App
    /// Store Connect, whose busy answers `Retry` waits out.
    static let concurrentChanges = 6

    /// Prints the plan, asks, and applies it: the end of every write command.
    func execute(_ plan: Plan, asc: AppStoreConnect, options: WriteOptions) async throws {
        guard try confirm(plan, options: options) else { return }
        try await apply(plan, asc: asc)
    }

    /// Prints the plan and asks. False when there is nothing to change or
    /// the run is dry; a refusal throws.
    func confirm(_ plan: Plan, options: WriteOptions) throws -> Bool {
        for warning in plan.warnings { warn(warning) }
        guard !plan.changes.isEmpty else {
            console.print("Nothing to change.")
            return false
        }
        console.print("")
        for line in plan.lines { console.print(line) }
        let count = counted(plan.changes.count, "change")
        console.print("")
        if options.dryRun {
            console.print("Dry run: \(count), nothing written.")
            return false
        }
        if !options.yes {
            guard console.isInteractive else { throw Stopped(description: "Pass --yes to apply without a terminal.") }
            let answer = console.readLine(prompt: "Apply \(count)? [y/N] ")?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else { throw Stopped(description: "Nothing changed.") }
        }
        return true
    }

    /// Makes every change of a confirmed plan, carrying on past a failed one,
    /// and fails when any did. Concurrent changes run up to `width` at a
    /// time, each reported as it ends; any other runs alone, in plan order.
    func apply(_ plan: Plan, asc: AppStoreConnect, width: Int = Self.concurrentChanges) async throws {
        let count = counted(plan.changes.count, "change")
        let run = Run(asc: asc)
        var failed = 0
        func report(_ change: Change, _ error: (any Error)?) {
            let label = "\(change.action.rawValue) \(change.subject)"
            if let error {
                failed += 1
                console.print("  failed  \(label): \(error)")
            } else {
                console.print("  done    \(label)")
            }
        }
        @Sendable func perform(_ change: Change) async -> (Change, (any Error)?) {
            do {
                try await change.perform(run)
                return (change, nil)
            } catch {
                return (change, error)
            }
        }
        await withTaskGroup(of: (Change, (any Error)?).self) { group in
            var running = 0
            for change in plan.changes {
                if !change.concurrent {
                    while let (done, error) = await group.next() { report(done, error) }
                    running = 0
                    let (done, error) = await perform(change)
                    report(done, error)
                    continue
                }
                if running == width, let (done, error) = await group.next() {
                    report(done, error)
                    running -= 1
                }
                group.addTask { await perform(change) }
                running += 1
            }
            while let (done, error) = await group.next() { report(done, error) }
        }
        guard failed == 0 else {
            console.print("\(plan.changes.count - failed) of \(count) applied, \(failed) failed.")
            throw ExitCode.failure
        }
        console.print("Applied \(count).")
    }
}

/// Runs `operation`, cancelling it when Control-C is pressed, so whatever it
/// started, simulators included, is cleaned up before the process exits.
func cancellingOnInterrupt<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let task = Task { try await operation() }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { task.cancel() }
    interrupt.resume()
    defer {
        interrupt.cancel()
        signal(SIGINT, SIG_DFL)
    }
    do {
        return try await task.value
    } catch is CancellationError {
        throw Stopped(description: "Stopped.")
    }
}

/// `--locales`, which every command that works per locale takes.
struct LocaleFlag: ParsableArguments {
    @Option(help: "Comma-separated locale codes. Default: all.")
    var locales = ""
}

/// `--platforms`, for the commands that work on screenshots.
struct PlatformFlag: ParsableArguments {
    @Option(help: "Comma-separated platform ids. Default: all.")
    var platforms = ""
}

/// `--dry-run` and `--yes`, which every write command takes.
struct WriteOptions: ParsableArguments {
    @Flag(help: "Show the plan and write nothing.")
    var dryRun = false
    @Flag(name: .shortAndLong, help: "Apply without asking.")
    var yes = false
}

/// The configured items a comma-separated flag names, or all of them when it
/// is empty.
private func selection<Item>(_ flag: String, from items: [Item], name: (Item) -> String, kind: String) throws -> [Item] {
    let names = flag.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !names.isEmpty else { return items }
    let known = items.map(name)
    let unknown = names.filter { !known.contains($0) }
    guard unknown.isEmpty else {
        throw Stopped(description: "Unknown \(kind) \(unknown.joined(separator: ", ")). This project has \(known.joined(separator: ", ")).")
    }
    return items.filter { names.contains(name($0)) }
}

extension Collection where Element: Sendable {
    /// `transform` of each element, up to `width` at a time, in the
    /// collection's order.
    func concurrentMap<T: Sendable>(width: Int, _ transform: @escaping @Sendable (Element) async throws -> T) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: count)
            for (index, element) in enumerated() {
                if index >= width, let (done, value) = try await group.next() { results[done] = value }
                group.addTask { (index, try await transform(element)) }
            }
            while let (done, value) = try await group.next() { results[done] = value }
            return results.map { $0! }
        }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
