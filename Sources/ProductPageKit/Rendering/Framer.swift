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
    var list: ShotList { subject.list }

    /// Where `export` puts it: beside the platform's own screenshots, in a
    /// folder of its own for a custom page's or treatment's, whose names
    /// repeat the store's.
    var exportPath: String { [platform.id, locale.code, list.folder, name].compactMap { $0 }.joined(separator: "/") }
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
        /// Every screenshot framed: each platform's list, then each custom
        /// page's and each treatment's, in order.
        var screenshots: [FramedScreenshot]
        var drawn: Int
        /// Caption lines shown in the source language for want of a
        /// translation: `screenshot.inbox.headline · da`.
        var untranslated: [String]
        /// Why each screenshot left out could not be framed.
        var problems: [RenderProblem<FramedItem>]
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
    enum Found: Sendable {
        case image(URL, highlights: Data?)
        case file(URL)

        var url: URL {
            switch self {
            case .image(let url, _), .file(let url): url
            }
        }

        /// An image and its highlights, read.
        func read() throws -> (image: CGImage, highlights: [CGRect])? {
            guard case .image(let url, let marks) = self else { return nil }
            return (try CGImage.read(try Data(contentsOf: url), from: url),
                    try marks.map { try JSONDecoder().decode(Highlights.self, from: $0).rects } ?? [])
        }
    }

    /// Frames every listed shot of `platforms` in `locales`, in the lists
    /// `lists` takes.
    func frame(platforms: [Platform], locales: [StoreLocale], lists: (ShotList) -> Bool = { _ in true }) async throws -> Report {
        let kinds = Set(platforms.map(\.kind))
        return try await frame(project.frameSubjects.filter { kinds.contains($0.platform) && lists($0.list) }, locales: locales)
    }

    /// Frames each of `subjects` in `locales` that has its sources and
    /// caption, and says why each other one could not be framed.
    func frame(_ subjects: [FrameSubject], locales: [StoreLocale]) async throws -> Report {
        let fileDigests = try await files.digests(for: subjects.flatMap(project.sources(for:)))
        var jobs: [Job] = []
        var captions = CaptionReader(copy)
        var problems: [RenderProblem<FramedItem>] = []
        var digests: [URL: String] = [:]
        // A list at a time, each locale's shots in order.
        let lists = Dictionary(grouping: subjects) { ListID(platform: $0.platform, list: $0.list) }
        let order = subjects.map { ListID(platform: $0.platform, list: $0.list) }.reduce(into: [ListID]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        for (list, locale) in order.flatMap({ list in locales.map { (list, $0) } }) {
            for subject in lists[list]! {
                guard let platform = project.platform(subject.platform),
                      let listing = project.listing(subject.list, on: subject.platform) else { continue }
                let position = listing.shots.firstIndex(of: subject.shot)!
                let item = FramedItem(subject, locale: locale)
                var reasons: [String] = []
                var key = RenderKey("framed")
                key.add(project.output.identifier)
                var found: [FrameSource: Found] = [:]
                let files = fileDigests.mapValues(\.0)
                for source in project.sources(for: subject) {
                    switch find(source, locale: locale, files: files) {
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
                        reasons.append(problem.description)
                    }
                }
                var caption: Caption?
                if let theme = project.frames {
                    switch captions.caption(listing.captionSubject(subject.shot), locale: locale) {
                    case .success(let read):
                        caption = read
                        for part in [subject.platform.rawValue, subject.list.folder ?? "", "\(position)", "\(listing.shots.count)", locale.code,
                                     theme.layoutKey(for: subject)] {
                            key.add(part)
                        }
                        key.add(read)
                    case .failure(let missing):
                        reasons.append(missing.description)
                    }
                }
                guard reasons.isEmpty else {
                    problems += reasons.map {
                        RenderProblem(item: item, reason: $0, description: "\($0) in \(locale.code), for \(subject)")
                    }
                    continue
                }
                let file = "\(key.finalize()).\(project.output.fileExtension)"
                let name = listing.fileName(for: subject.shot)
                jobs.append(Job(
                    item: item,
                    screenshot: FramedScreenshot(subject: subject, platform: platform, locale: locale,
                                                 url: cache.framed.appending(path: file), name: "\(name).\(project.output.fileExtension)"),
                    position: position, count: listing.shots.count, caption: caption, sources: found))
            }
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

        // Each run names the files it framed, and drops what it was asked
        // to frame but could not, and what the project no longer frames.
        let asked = Set(subjects.flatMap { subject in locales.map { FramedItem(subject, locale: $0) } })
        let configured = Set(project.frameSubjects.flatMap { subject in project.locales.map { FramedItem(subject, locale: $0) } })
        try CacheIndex.update(in: cache.framed, with: jobs.map { ($0.item, $0.screenshot.url.lastPathComponent) }) {
            asked.contains($0) || !configured.contains($0)
        }
        return Report(screenshots: jobs.map(\.screenshot), drawn: missing.count, untranslated: captions.untranslated,
                      problems: problems)
    }

    /// A platform's own list, or a custom page's or treatment's on a platform.
    private struct ListID: Hashable {
        let platform: Platform.Kind
        let list: ShotList
    }

    /// A file's bytes, hashed without keeping them.
    private static func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).hex
    }

    /// Where `source` is in `locale`, `files` being where each prepared
    /// file is.
    func find(_ source: FrameSource, locale: StoreLocale, files: [String: URL]) -> Result<Found, Problem> {
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
            guard let url = files[name] else { return .failure(Problem("no file \(name)")) }
            return .success(.file(url))
        }
    }

    struct Problem: Error, CustomStringConvertible {
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
                if let (image, marks) = try place.read() {
                    images[source] = image
                    highlights[source] = marks
                } else if case .file(let name) = source.content {
                    files[name] = place.url
                }
            }
            let shot = FramedShot(shot: subject.shot, list: subject.list, position: job.position, count: job.count,
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
