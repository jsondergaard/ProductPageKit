import ArgumentParser
import Foundation
import ProductPageKitASC
import ProductPageKitCore
import ProductPageKitRunner

extension Commands {
    /// The app's builds on the platforms it archives, newest upload first.
    static func listBuilds(_ session: Session, platforms flag: String, limit: Int) async throws {
        try session.checkProject()
        guard limit > 0 else { throw Stopped(description: "--limit takes 1 or more.") }
        let platforms = try session.buildPlatforms(flag)
        let asc = try session.connect()
        let app = try await asc.app(bundleID: session.project.bundleID)
        let builds = try await asc.builds(appID: app.id).filter { $0.platform.map(platforms.contains) ?? false }
        guard !builds.isEmpty else {
            session.console.print("App Store Connect has no \(session.project.name) builds for \(platforms.map(\.name).joined(separator: ", ")).")
            return
        }
        let shown = builds.prefix(limit)
        let names = shown.map { "\($0.version ?? "?") (\($0.number))" }
        let width = names.map(\.count).max() ?? 0
        for (build, name) in zip(shown, names) {
            let columns = [
                name.padding(toLength: width, withPad: " ", startingAt: 0),
                (build.platform?.name ?? "").padding(toLength: 9, withPad: " ", startingAt: 0),
                (build.expired ? "expired" : Self.state(build.processingState)).padding(toLength: 11, withPad: " ", startingAt: 0),
                Self.audience(build.audience).padding(toLength: 15, withPad: " ", startingAt: 0),
                build.uploaded?.formatted(date: .abbreviated, time: .shortened) ?? "",
            ]
            session.console.print(columns.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
        if builds.count > limit { session.console.print("\(counted(builds.count - limit, "older build")) not shown; --limit shows more.") }
    }

    static func state(_ processingState: String?) -> String {
        switch processingState {
        case "VALID": "ready"
        case "PROCESSING": "processing"
        case "FAILED": "failed"
        case "INVALID": "invalid"
        default: processingState?.lowercased() ?? ""
        }
    }

    static func audience(_ audience: String?) -> String {
        switch audience {
        case "INTERNAL_ONLY": "internal only"
        case "APP_STORE_ELIGIBLE": "App Store"
        default: audience?.lowercased() ?? ""
        }
    }

    /// Numbers the next build after the highest App Store Connect has, shows
    /// the plan and asks, archives every platform, and then uploads each.
    static func uploadBuilds(_ session: Session, platforms flag: String, options: WriteOptions,
                             archives: URL = Archiver.xcodeArchives) async throws {
        try session.checkProject()
        guard let builds = session.project.builds else { throw ArchiveError.notConfigured }
        let platforms = try session.buildPlatforms(flag)
        let credentials = try Credentials(environment: session.environment)
        guard let file = credentials.keyFile else { throw Stopped(description: "ASC_KEY_PATH names no .p8 file for xcodebuild.") }
        let asc = try session.connect()
        let app = try await asc.app(bundleID: session.project.bundleID)
        let number = builds.numbering.number(after: try await asc.builds(appID: app.id).compactMap { BuildNumber($0.number) })
        let console = session.console
        let archiver = try Archiver(project: session.project, root: session.root, cache: session.cache,
                                    key: APIKey(file: file, id: credentials.keyID, issuer: credentials.issuerID),
                                    archives: archives) { console.print($0) }
        let shelf = ArchiveShelf()
        var plan = Plan()
        for platform in platforms {
            plan.add(Change(action: .upload, subject: "\(session.project.name) \(platform.name) build \(number)",
                            lines: ["for \(builds.audience)"]) { _ in
                try await archiver.upload(try await shelf.archive(for: platform))
            })
        }
        guard try session.confirm(plan, options: options) else { return }
        let confirmed = plan
        try await cancellingOnInterrupt {
            await shelf.store(try await archiver.archive(platforms, number: number))
            try await session.apply(confirmed, asc: asc)
        }
        console.print("TestFlight offers each build once App Store Connect has processed it; `productpage builds list` shows where it is.")
    }
}

/// The archives an upload plan's changes send, made after the plan is
/// confirmed.
private actor ArchiveShelf {
    private var archives: [StorePlatform: Archive] = [:]

    func store(_ made: [Archive]) {
        for archive in made { archives[archive.platform] = archive }
    }

    func archive(for platform: StorePlatform) throws -> Archive {
        guard let archive = archives[platform] else { throw Stopped(description: "\(platform.name) was not archived.") }
        return archive
    }
}

// MARK: - Command line

struct BuildsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "builds", abstract: "TestFlight builds, archived from the Xcode project.",
                                                    subcommands: [List.self, Upload.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the builds App Store Connect has, newest first.")
        @Option(help: "Comma-separated: ios, macos, tvos, visionos. Default: every platform builds are archived for.") var platforms = ""
        @Option(help: "How many builds to show.") var limit = 20

        func run() async throws { try await Commands.listBuilds(try Session.get(), platforms: platforms, limit: limit) }
    }

    struct Upload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Archive every platform as the next build, then upload each to TestFlight. Never submits for review."
        )
        @Option(help: "Comma-separated: ios, macos, tvos, visionos. Default: every platform builds are archived for.") var platforms = ""
        @OptionGroup var options: WriteOptions

        func run() async throws { try await Commands.uploadBuilds(try Session.get(), platforms: platforms, options: options) }
    }
}
