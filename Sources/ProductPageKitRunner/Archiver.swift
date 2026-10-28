public import Foundation
public import ProductPageKitCore

/// An App Store Connect API key on disk. `xcodebuild` signs with it,
/// creating certificates and profiles as it needs, and uploads with it.
public struct APIKey: Sendable {
    public let file: URL
    public let id: String
    public let issuer: String

    public init(file: URL, id: String, issuer: String) {
        self.file = file
        self.id = id
        self.issuer = issuer
    }

    var arguments: [String] {
        ["-authenticationKeyPath", file.path, "-authenticationKeyID", id, "-authenticationKeyIssuerID", issuer]
    }
}

/// The app archived for one platform.
public struct Archive: Equatable, Sendable {
    public let platform: StorePlatform
    public let url: URL
    /// Its `CFBundleShortVersionString`.
    public let version: String
    public let number: BuildNumber
}

/// Archives the app and uploads the archives to TestFlight.
public struct Archiver: Sendable {
    let project: Project
    let builds: Builds
    let xcode: XcodeProject
    let root: URL
    let cache: Cache
    let key: APIKey
    /// Where archives go: `<folder>/<yyyy-MM-dd>/<name>.xcarchive`.
    let archives: URL
    let log: @Sendable (String) -> Void

    /// Xcode's own archive folder, whose archives the Organizer lists.
    public static var xcodeArchives: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/Xcode/Archives")
    }

    public init(project: Project, root: URL, cache: Cache, key: APIKey, archives: URL = Archiver.xcodeArchives,
                log: @escaping @Sendable (String) -> Void) throws {
        guard let xcode = project.xcode else { throw RunnerError.noXcodeProject }
        guard let builds = project.builds else { throw ArchiveError.notConfigured }
        self.project = project
        self.builds = builds
        self.xcode = xcode
        self.root = root
        self.cache = cache
        self.key = key
        self.archives = archives
        self.log = log
    }

    /// Archives every platform as build `number`, one at a time, and returns
    /// the archives once the project's `afterArchive` commands have run on
    /// each. An archive's commands run while the next platform archives:
    /// they are mostly uploads, and two archives at once need more memory
    /// than most Macs have. Any failure stops the run, so nothing is
    /// returned to upload.
    public func archive(_ platforms: [StorePlatform], number: BuildNumber, date: Date = Date()) async throws -> [Archive] {
        for command in xcode.before {
            log("Running \(command)")
            _ = try await Shell.run(command, in: root)
        }
        let build = XcodeBuild(xcode: xcode, root: root, cache: cache, bundleID: project.bundleID, log: log)
        let folder = archives.appending(path: date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (archived, finished) = AsyncStream.makeStream(of: Archive.self)
        return try await withThrowingTaskGroup(of: [Archive].self) { group in
            group.addTask {
                defer { finished.finish() }
                var made: [Archive] = []
                for platform in platforms {
                    let archive = try await archive(platform, number: number, in: folder, with: build)
                    made.append(archive)
                    finished.yield(archive)
                }
                return made
            }
            group.addTask {
                for await archive in archived { try await runAfterArchive(archive) }
                return []
            }
            // The first failure leaves this loop, which cancels the other task.
            var made: [Archive] = []
            for try await archives in group { made += archives }
            return made
        }
    }

    private func archive(_ platform: StorePlatform, number: BuildNumber, in folder: URL, with build: XcodeBuild) async throws -> Archive {
        let url = folder.appending(path: "\(project.name) \(platform.name) \(number).xcarchive")
        try? FileManager.default.removeItem(at: url)
        log("Archiving \(project.name) build \(number) for \(platform.name)")
        try await build.archive(platform, number: number, to: url, key: key)
        let archive = try read(url, platform: platform, number: number)
        log("Archived \(project.name) \(archive.version) (\(number)) for \(platform.name): \(url.path)")
        return archive
    }

    private func runAfterArchive(_ archive: Archive) async throws {
        for command in builds.afterArchive {
            log("Running \(command) for \(archive.platform.name)")
            let output = try await Shell.run("/bin/zsh", ["-c", command], in: root,
                                             environment: [Builds.archiveVariable: archive.url.path], describedAs: command)
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { log(text) }
        }
    }

    /// Uploads `archive` to App Store Connect, which processes it before
    /// TestFlight offers it to testers.
    public func upload(_ archive: Archive) async throws {
        let folder = cache.logs.appending(path: "\(archive.platform.key)-upload")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options = folder.appending(path: "ExportOptions.plist")
        try PropertyListSerialization.data(fromPropertyList: Self.exportOptions(builds.audience), format: .xml, options: 0)
            .write(to: options)
        log("Uploading \(project.name) \(archive.version) (\(archive.number)) for \(archive.platform.name)")
        let build = XcodeBuild(xcode: xcode, root: root, cache: cache, bundleID: project.bundleID, log: log)
        try await build.export(archive, options: options, to: folder, key: key)
    }

    /// What `xcodebuild -exportArchive` is told: upload to App Store Connect
    /// for `audience`, signed automatically, keeping the archive's number.
    static func exportOptions(_ audience: TestFlightAudience) -> [String: Any] {
        [
            "method": "app-store-connect",
            "destination": "upload",
            "signingStyle": "automatic",
            "manageAppVersionAndBuildNumber": false,
            "testFlightInternalTestingOnly": audience == .internalOnly,
            "uploadSymbols": true,
        ]
    }

    /// The archive at `url`, checked to hold the project's app numbered
    /// `number`.
    func read(_ url: URL, platform: StorePlatform, number: BuildNumber) throws -> Archive {
        let info = NSDictionary(contentsOf: url.appending(path: "Info.plist"))
        guard let app = info?["ApplicationProperties"] as? [String: Any] else { throw ArchiveError.noApp(url.path) }
        let bundleID = app["CFBundleIdentifier"] as? String ?? ""
        guard bundleID == project.bundleID else { throw ArchiveError.wrongApp(url.path, bundleID: bundleID, expected: project.bundleID) }
        let found = app["CFBundleVersion"] as? String ?? ""
        guard BuildNumber(found) == number else { throw ArchiveError.numberNotApplied(platform.name, found: found, expected: number) }
        return Archive(platform: platform, url: url, version: app["CFBundleShortVersionString"] as? String ?? "", number: number)
    }
}

public enum ArchiveError: Error, CustomStringConvertible {
    case notConfigured
    case noApp(String)
    case wrongApp(String, bundleID: String, expected: String)
    case numberNotApplied(String, found: String, expected: BuildNumber)

    public var description: String {
        switch self {
        case .notConfigured:
            "The project has no builds to upload (Project.builds)."
        case .noApp(let path):
            "\(path) holds no app; is the scheme's archive action building it?"
        case .wrongApp(let path, let bundleID, let expected):
            "\(path) holds \(bundleID), not \(expected)."
        case .numberNotApplied(let platform, let found, let expected):
            """
            The \(platform) archive is build \(found.isEmpty ? "(none)" : found), not \(expected). The app's Info.plist must \
            take CFBundleVersion from $(CURRENT_PROJECT_VERSION).
            """
        }
    }
}
