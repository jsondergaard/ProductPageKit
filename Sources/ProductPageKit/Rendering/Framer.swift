import CoreGraphics
import CryptoKit
import Foundation
import ProductPageKitCore
import ProductPageKitFrames

/// A framed screenshot in the cache, as it is uploaded.
struct FramedScreenshot: Sendable {
    let subject: FrameSubject
    let platform: Platform
    let locale: StoreLocale
    let url: URL
    /// `01_inbox.png`: what App Store Connect is told the file is called.
    let name: String

    var shot: Shot { subject.shot }
    var page: String? { subject.page }
}

/// Frames captures into the cache with the project's theme, drawing only the
/// screenshots whose sources, caption or theme changed.
struct Framer {
    let copy: StoreCopy
    let cache: Cache
    let files: CaptureFileStore

    init(copy: StoreCopy, cache: Cache, log: @escaping @Sendable (String) -> Void) {
        self.copy = copy
        self.cache = cache
        files = CaptureFileStore(project: copy.project, cache: cache, log: log)
    }

    var project: Project { copy.project }

    struct Report {
        /// Every screenshot of the platforms and locales framed: each
        /// platform's list, then each custom page's, in order.
        var screenshots: [FramedScreenshot]
        var drawn: Int
        /// Caption lines shown in the source language for want of a
        /// translation: `screenshot.inbox.headline · da`.
        var untranslated: [String]

        /// The platform lists' screenshots, without the custom pages'.
        var store: [FramedScreenshot] { screenshots.filter { $0.page == nil } }
    }

    /// One screenshot to frame, keyed. Its sources are read again only if
    /// it has to be drawn, since a full set holds more than fits in memory.
    private struct Job: Sendable {
        let item: FramedItem
        let screenshot: FramedScreenshot
        let position: Int
        let count: Int
        /// Nil without a theme.
        let caption: Caption?
        let sources: [FrameSource: Found]
    }

    /// Where a source is in the cache.
    private enum Found: Sendable {
        case image(URL, highlights: Data?)
        case file(URL)
    }

    func frame(platforms: [Platform], locales: [StoreLocale]) async throws -> Report {
        let kinds = Set(platforms.map(\.kind))
        let subjects = project.frameSubjects.filter { kinds.contains($0.platform) }
        let fileDigests = try await files.digests(for: subjects.flatMap(project.sources(for:)))
        var jobs: [Job] = []
        var captions = CaptionReader(copy)
        var problems: [String] = []
        var digests: [URL: String] = [:]
        // A list at a time, each locale's shots in order.
        let lists = Dictionary(grouping: subjects) { ListID(platform: $0.platform.rawValue, page: $0.page) }
        let order = subjects.map { ListID(platform: $0.platform.rawValue, page: $0.page) }.reduce(into: [ListID]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        for (list, locale) in order.flatMap({ list in locales.map { (list, $0) } }) {
            for subject in lists[list]! {
                guard let platform = project.platform(subject.platform) else { continue }
                let page = subject.page.flatMap(project.customPage)
                let list = page?.shots ?? platform.shots
                let position = list.firstIndex(of: subject.shot)!
                let sources = project.sources(for: subject)
                var key = RenderKey("framed")
                key.add(project.output.identifier)
                var found: [FrameSource: Found] = [:]
                for source in sources {
                    switch find(source, locale: locale, files: fileDigests) {
                    case .success(let place):
                        found[source] = place
                        key.add(source.description)
                        switch place {
                        case .image(let url, let highlights):
                            if digests[url] == nil { digests[url] = try Self.digest(of: url) }
                            key.add(digests[url]!)
                            key.add(highlights ?? Data())
                        case .file(let url):
                            key.add(fileDigests.values.first { $0.0 == url }!.1)
                        }
                    case .failure(let problem):
                        problems.append("\(problem) in \(locale.code), for \(describe(subject))")
                    }
                }
                guard found.count == sources.count else { continue }
                var caption: Caption?
                if project.frames != nil {
                    guard let read = captions.caption(page?.captionSubject(subject.shot) ?? .screenshot(subject.shot), locale: locale)
                    else { continue }
                    caption = read
                    for part in [subject.platform.rawValue, subject.page ?? "", "\(position)", "\(list.count)", locale.code] {
                        key.add(part)
                    }
                    key.add(read)
                }
                let file = "\(key.finalize()).\(project.output.fileExtension)"
                let name = page?.fileName(for: subject.shot) ?? platform.fileName(for: subject.shot)
                jobs.append(Job(
                    item: FramedItem(subject, locale: locale),
                    screenshot: FramedScreenshot(subject: subject, platform: platform, locale: locale,
                                                 url: cache.framed.appending(path: file), name: "\(name).\(project.output.fileExtension)"),
                    position: position, count: list.count, caption: caption, sources: found))
            }
        }
        problems += captions.problems
        guard problems.isEmpty else {
            throw Stopped(description: "Nothing framed:\n" + problems.map { "  \($0)" }.joined(separator: "\n")
                          + "\n`productpage screenshots capture` takes the captures; the catalog holds the captions.")
        }

        try FileManager.default.createDirectory(at: cache.framed, withIntermediateDirectories: true)
        let missing = jobs.filter { !FileManager.default.fileExists(atPath: $0.screenshot.url.path) }
        let theme = project.frames
        let output = project.output
        try await withThrowingTaskGroup { group in
            for job in missing {
                group.addTask { try Self.draw(job, theme: theme, output: output) }
            }
            try await group.waitForAll()
        }

        let platformIDs = Set(platforms.map(\.kind.rawValue))
        let localeCodes = Set(locales.map(\.code))
        let configuredLists = Set(project.frameSubjects.map { ListID(platform: $0.platform.rawValue, page: $0.page) })
        let configuredLocales = Set(project.locales.map(\.code))
        try CacheIndex.update(in: cache.framed, with: jobs.map { ($0.item, $0.screenshot.url.lastPathComponent) }) {
            (platformIDs.contains($0.platform) && localeCodes.contains($0.locale))
                || !configuredLists.contains(ListID(platform: $0.platform, page: $0.page)) || !configuredLocales.contains($0.locale)
        }
        return Report(screenshots: jobs.map(\.screenshot), drawn: missing.count, untranslated: captions.untranslated)
    }

    /// A platform's list, or a custom page's on a platform.
    private struct ListID: Hashable {
        let platform: String
        let page: String?
    }

    /// A file's bytes, hashed without keeping them.
    private static func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).hex
    }

    private func describe(_ subject: FrameSubject) -> String {
        "the \(subject.platform.name) \(subject.shot) screenshot" + (subject.page.map { " of the \($0) page" } ?? "")
    }

    private func find(_ source: FrameSource, locale: StoreLocale, files: [String: (URL, String)]) -> Result<Found, Problem> {
        let locale = source.isInPrimaryLocale ? project.primaryLocale : locale
        switch source.content {
        case .capture(let shot, let kind):
            guard let platform = project.platform(kind) else { return .failure(Problem("no \(kind.name) platform")) }
            let url = cache.capture(platform, locale, shot)
            guard FileManager.default.fileExists(atPath: url.path) else { return .failure(Problem("no \(platform.name) capture of \(shot)")) }
            return .success(.image(url, highlights: Highlights.data(for: url)))
        case .component(let component, let kind):
            guard let platform = project.platform(kind) else { return .failure(Problem("no \(kind.name) platform")) }
            let url = cache.component(platform, locale, component)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(Problem("no \(platform.name) component \(component)"))
            }
            return .success(.image(url, highlights: nil))
        case .file(let name):
            guard let (url, _) = files[name] else { return .failure(Problem("no file \(name)")) }
            return .success(.file(url))
        }
    }

    private struct Problem: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func draw(_ job: Job, theme: (any FrameTheme)?, output: ImageFormat) throws {
        let subject = job.screenshot.subject
        if let theme, let caption = job.caption {
            var images: [FrameSource: CGImage] = [:]
            var highlights: [FrameSource: [CGRect]] = [:]
            var files: [String: URL] = [:]
            for (source, place) in job.sources {
                switch place {
                case .image(let url, let marks):
                    images[source] = try CGImage.read(try Data(contentsOf: url), from: url)
                    highlights[source] = try marks.map { try JSONDecoder().decode(Highlights.self, from: $0).rects } ?? []
                case .file(let url):
                    if case .file(let name) = source.content { files[name] = url }
                }
            }
            let shot = FramedShot(shot: subject.shot, page: subject.page, position: job.position, count: job.count,
                                  platform: subject.platform, locale: job.screenshot.locale, caption: caption, images: images,
                                  highlights: highlights, files: files)
            let canvas = Canvas(size: theme.canvasSize(for: subject.platform))
            try theme.render(shot, on: canvas)
            try output.encode(canvas.image()).write(to: job.screenshot.url, options: .atomic)
            return
        }
        guard case .image(let url, _)? = job.sources[.capture(subject.shot, on: subject.platform)] else {
            throw Stopped(description: "\(job.screenshot.name) has no capture to upload")
        }
        let capture = try Data(contentsOf: url)
        let image = try CGImage.read(capture, from: url)
        let platform = job.screenshot.platform
        guard platform.kind.acceptedSizes.contains(image.size) else {
            throw Stopped(description: "\(platform.name) \(job.screenshot.name) in \(job.screenshot.locale.code) is "
                          + "\(image.width) × \(image.height), which App Store Connect does not take. Frame it with a theme, "
                          + "or capture on a device whose screen is a size it takes.")
        }
        try (output == .png ? capture : try output.encode(image)).write(to: job.screenshot.url, options: .atomic)
    }
}

/// The project's capture files, prepared in the cache on first use.
struct CaptureFileStore: Sendable {
    let project: Project
    let cache: Cache
    let log: @Sendable (String) -> Void

    /// Prepares the files `sources` name and returns each one's place and a
    /// digest of its bytes.
    func digests(for sources: [FrameSource]) async throws -> [String: (URL, String)] {
        let names = Set(sources.compactMap { source -> String? in
            if case .file(let name) = source.content { name } else { nil }
        })
        guard !names.isEmpty else { return [:] }
        let directory = try await prepare()
        var digests: [String: (URL, String)] = [:]
        for name in names {
            let url = directory.appending(path: name)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw Stopped(description: "The project's capture files did not prepare \(name).")
            }
            digests[name] = (url, SHA256.hash(data: data).hex)
        }
        return digests
    }

    /// Where the files are, once each is there.
    func prepare() async throws -> URL {
        guard let files = project.files else { throw Stopped(description: "The project has no capture files.") }
        try FileManager.default.createDirectory(at: cache.files, withIntermediateDirectories: true)
        try await files.prepare(in: cache.files, log: log)
        return cache.files
    }
}
