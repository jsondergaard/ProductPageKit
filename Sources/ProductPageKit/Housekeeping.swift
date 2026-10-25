import ArgumentParser
import Foundation
import ProductPageKitCore

extension Commands {
    /// Frames the screenshots and renders the videos, then copies them to
    /// `<directory>/<platform>/<locale>/` and `<directory>/videos/<locale>/`.
    static func export(_ session: Session, to directory: String) async throws {
        try session.checkProject()
        let project = session.project
        let destination = URL(filePath: directory, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        var files: [(URL, String)] = try await frameScreenshots(session, platforms: project.platforms, locales: project.locales)
            .screenshots.map { ($0.url, $0.exportPath) }
        if project.videos != nil {
            files += try await renderVideos(session, locales: project.locales).videos
                .map { ($0.url, "videos/\($0.locale.code)/\($0.asset.kind.rawValue).mp4") }
        }
        var uncaptured: [String] = []
        for render in project.renders {
            guard let platform = project.platform(render.source.platform) else { continue }
            let file = session.cache.file(render, on: platform, in: project.primaryLocale)
            guard FileManager.default.fileExists(atPath: file.path) else {
                uncaptured.append(render.name)
                continue
            }
            files.append((file, "renders/\(platform.id)/\(render.name).png"))
        }
        if !uncaptured.isEmpty {
            throw Stopped(description: "Not captured yet, so `screenshots capture` first: \(uncaptured.joined(separator: ", ")).")
        }
        for (source, path) in files {
            let target = destination.appending(path: path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        session.console.print("Exported \(counted(files.count, "file")) to \(destination.path).")
    }

    /// What each part of the app's cache holds.
    static func cacheSize(_ session: Session) throws {
        let cache = session.cache
        var total: Int64 = 0
        for (name, url) in cacheParts(cache) {
            let size = try directorySize(url)
            total += size
            session.console.print(name.padding(toLength: 12, withPad: " ", startingAt: 0) + format(size))
        }
        session.console.print("total".padding(toLength: 12, withPad: " ", startingAt: 0) + format(total) + "  in \(cache.directory.path)")
    }

    /// Deletes what the next run rebuilds on its own, the build and its
    /// logs, and the frames and videos nothing points to. The captures and
    /// the current frames and videos stay, so nothing needs capturing again.
    static func pruneCache(_ session: Session) throws {
        let cache = session.cache
        let before = try directorySize(cache.directory)
        for url in [cache.derivedData, cache.logs] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if FileManager.default.fileExists(atPath: cache.framed.path) { try CacheIndex<FramedItem>.prune(in: cache.framed) }
        if FileManager.default.fileExists(atPath: cache.videos.path) { try CacheIndex<VideoItem>.prune(in: cache.videos) }
        session.console.print("Freed \(format(before - (try directorySize(cache.directory)))).")
    }

    static func cacheParts(_ cache: Cache) -> [(String, URL)] {
        [("build", cache.derivedData), ("captures", cache.directory.appending(path: "raw")),
         ("review", cache.directory.appending(path: "review")), ("framed", cache.framed), ("videos", cache.videos),
         ("logs", cache.logs)]
    }

    static func directorySize(_ url: URL) throws -> Int64 {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return 0
        }
        var size: Int64 = 0
        for case let file as URL in files {
            size += Int64(try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        }
        return size
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Copy the framed screenshots and the videos out of the cache, framing and rendering first."
    )
    @Argument(help: "The directory to copy into.") var directory: String

    func run() async throws {
        let session = try Session.get()
        let directory = directory
        try await cancellingOnInterrupt { try await Commands.export(session, to: directory) }
    }
}

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cache", abstract: "The app's files in ~/Library/Caches/ProductPageKit.",
                                                    subcommands: [Size.self, Prune.self])

    struct Size: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show what each part of the cache holds.")
        func run() async throws { try Commands.cacheSize(try Session.get()) }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete the build, its logs, and frames and videos nothing points to. Captures stay."
        )
        func run() async throws { try Commands.pruneCache(try Session.get()) }
    }
}
