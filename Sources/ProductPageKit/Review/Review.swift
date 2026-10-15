import CryptoKit
import Foundation
import ProductPageKitASC
import ProductPageKitCore
import ProductPageKitRunner

/// What the review page shows, read fresh from disk on every request so edits
/// made in Xcode or by an agent appear without a restart.
struct ReviewState: Codable, Equatable {
    struct Locale: Codable, Equatable {
        let code: String
        let store: String
    }

    struct FieldInfo: Codable, Equatable {
        let key: String
        let title: String
        let maxLength: Int?
        let translatable: Bool
        /// The catalog's comment: how to write this field.
        let comment: String?
    }

    struct Unit: Codable, Equatable {
        let value: String
        let state: String
    }

    struct Issue: Codable, Equatable {
        let severity: String
        let message: String
    }

    struct PlatformInfo: Codable, Equatable {
        let id: String
        let name: String
        let width: Int
        let height: Int
        /// The catalog key prefix of each shot's caption, in store order, or
        /// nil without a theme.
        let captions: [String]?
    }

    struct Screenshot: Codable, Equatable {
        let platform: String
        let locale: String
        let position: Int
        let url: String
    }

    struct Video: Codable, Equatable {
        let kind: String
        let title: String
        let locale: String
        /// The key prefix of its caption.
        let caption: String
        let width: Int
        let height: Int
        /// Nil until it is rendered.
        let url: String?
        /// False when its caption or captures changed since it was rendered.
        let current: Bool
    }

    let app: String
    let catalog: String
    /// Whether `/media/icon` serves the app icon.
    let icon: Bool
    let sourceLanguage: String
    /// Changes whenever the catalog file does.
    let revision: String
    let locales: [Locale]
    /// Listing fields, then each release newest first, then the review notes.
    let fields: [FieldInfo]
    let values: [String: [String: Unit]]
    /// The values in the last commit, for "changed since".
    let committed: [String: [String: String]]
    let problems: [Issue]
    let platforms: [PlatformInfo]
    let screenshots: [Screenshot]
    let videos: [Video]
    /// Why there are no screenshots or videos to show, such as captures not
    /// taken yet.
    let mediaProblems: [String]
}

/// The review page's API: read the copy, edit a value, approve a
/// translation, compare with App Store Connect.
actor Review {
    let session: Session

    init(session: Session) {
        self.session = session
    }

    var project: Project { session.project }

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        do {
            switch (request.method, request.path) {
            case ("GET", "/"):
                guard let url = Bundle.module.url(forResource: "review", withExtension: "html") else {
                    return .error(500, "the review page is missing from the package")
                }
                return HTTPServer.Response(status: 200, contentType: "text/html; charset=utf-8", body: try Data(contentsOf: url))
            case ("GET", "/api/state"):
                return .json(try await state())
            case ("GET", "/api/revision"):
                return .json(["revision": try revision()])
            case ("PUT", "/api/value"):
                let edit = try JSONDecoder().decode(Edit.self, from: request.body)
                try set(edit.value, key: edit.key, language: edit.language)
                return .json(try await state())
            case ("POST", "/api/approve"):
                let target = try JSONDecoder().decode(Target.self, from: request.body)
                try approve(key: target.key, language: target.language)
                return .json(try await state())
            case ("GET", let path) where path.hasPrefix("/api/live"):
                return .json(try await live())
            case ("GET", "/media/icon"):
                guard let icon = project.icon else { return .error(404, "the project has no icon") }
                return try .file(session.root.appending(path: icon), contentType: "image/png", range: nil)
            case ("GET", let path) where path.hasPrefix("/media/"):
                return try media(String(path.dropFirst("/media/".count)), range: request.headers["range"])
            default:
                return .error(404, "no such page")
            }
        } catch let error as Stopped {
            return .error(400, error.description)
        } catch let error as DecodingError {
            return .error(400, "unreadable request: \(error)")
        } catch {
            return .error(502, "\(error)")
        }
    }

    struct Edit: Decodable {
        let key: String
        let language: String
        let value: String
    }

    struct Target: Decodable {
        let key: String
        let language: String
    }

    /// Changes whenever the catalog does, a capture is taken or a video is
    /// rendered.
    func revision() throws -> String {
        var hash = SHA256()
        hash.update(data: (try? Data(contentsOf: StoreCopy.url(project, root: session.root))) ?? Data())
        for directory in [session.cache.directory.appending(path: "raw"), session.cache.directory.appending(path: "components"),
                          session.cache.videos] {
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for case let file as URL in files {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                hash.update(data: Data("\(file.path) \(date.timeIntervalSince1970)\n".utf8))
            }
        }
        return hash.finalize().prefix(8).hex
    }

    /// A framed screenshot or a rendered video, by its file name in the cache.
    func media(_ name: String, range: String?) throws -> HTTPServer.Response {
        let pattern = /[0-9a-f]{32}\.(png|jpg|mp4)/
        guard let match = name.wholeMatch(of: pattern) else { return .error(404, "no such file") }
        let type = ["png": "image/png", "jpg": "image/jpeg", "mp4": "video/mp4"][String(match.1)]!
        let directory = match.1 == "mp4" ? session.cache.videos : session.cache.framed
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .error(404, "no such file") }
        return try .file(url, contentType: type, range: range)
    }

    func state() async throws -> ReviewState {
        let copy = try session.copy()
        let (screenshots, videos, mediaProblems) = await media(copy)
        return ReviewState(
            app: project.name,
            catalog: project.metadata.catalog,
            icon: project.icon != nil,
            sourceLanguage: copy.catalog.sourceLanguage,
            revision: try revision(),
            locales: project.locales.map { ReviewState.Locale(code: $0.code, store: $0.store) },
            fields: copy.fields.map {
                ReviewState.FieldInfo(key: $0.key, title: $0.title, maxLength: $0.maxLength, translatable: $0.isTranslatable,
                                      comment: copy.catalog.strings[$0.key]?.comment)
            },
            values: copy.catalog.strings.mapValues { entry in
                (entry.localizations ?? [:]).compactMapValues { localization in
                    localization.stringUnit.map { ReviewState.Unit(value: $0.value, state: $0.state) }
                }
            },
            committed: await committed(),
            problems: copy.problems().map {
                ReviewState.Issue(severity: $0.severity == .error ? "error" : "warning", message: $0.message)
            },
            platforms: strips(),
            screenshots: screenshots,
            videos: videos,
            mediaProblems: mediaProblems
        )
    }

    /// A strip of screenshots per platform, then one per custom page on each
    /// of its platforms, with each position's caption key.
    func strips() -> [ReviewState.PlatformInfo] {
        let platforms = project.platforms.filter { !$0.shots.isEmpty }.map { platform in
            ReviewState.PlatformInfo(
                id: platform.id, name: platform.name, width: Int(canvasSize(platform.kind).width),
                height: Int(canvasSize(platform.kind).height),
                captions: project.frames == nil ? nil : platform.shots.map { CaptionSubject.screenshot($0).key })
        }
        let pages = project.customPages.flatMap { page in
            page.platforms.map { kind in
                ReviewState.PlatformInfo(
                    id: Self.stripID(kind, page: page.key), name: "\(page.name) page, \(kind.name)",
                    width: Int(canvasSize(kind).width), height: Int(canvasSize(kind).height),
                    captions: project.frames == nil ? nil : page.shots.map { page.captionSubject($0).key })
            }
        }
        return platforms + pages
    }

    /// Frames the screenshots, so a caption edited here shows at once, and
    /// lists the videos as last rendered: a video takes too long to render on
    /// every edit, so one whose inputs changed is marked out of date.
    func media(_ copy: StoreCopy) async -> ([ReviewState.Screenshot], [ReviewState.Video], [String]) {
        var problems: [String] = []
        var screenshots: [ReviewState.Screenshot] = []
        do {
            let console = session.console
            screenshots = try await Framer(copy: copy, cache: session.cache) { console.print($0) }
                .frame(platforms: project.platforms, locales: project.locales).screenshots.map { screenshot in
                    let list = screenshot.page.flatMap(project.customPage)?.shots ?? screenshot.platform.shots
                    return ReviewState.Screenshot(platform: Self.stripID(screenshot.platform.kind, page: screenshot.page),
                                                  locale: screenshot.locale.code, position: list.firstIndex(of: screenshot.shot)!,
                                                  url: "/media/\(screenshot.url.lastPathComponent)")
                }
        } catch {
            problems.append("\(error)")
        }
        guard let theme = project.videos else { return (screenshots, [], problems) }
        let console = session.console
        let renderer = VideoRenderer(copy: copy, cache: session.cache, theme: theme) { console.print($0) }
        let inputs: VideoRenderer.Sources
        do {
            inputs = try await renderer.sources(locales: project.locales)
        } catch {
            return (screenshots, [], problems + ["\(error)"])
        }
        problems += inputs.problems
        let index = CacheIndex<VideoItem>.read(in: session.cache.videos)
        var videos: [ReviewState.Video] = []
        for asset in theme.assets {
            for locale in project.locales {
                let item = VideoItem(kind: asset.kind, locale: locale)
                let file = index.file(for: item)
                videos.append(ReviewState.Video(
                    kind: asset.kind.rawValue, title: asset.kind.title, locale: locale.code, caption: "video.\(asset.kind.rawValue)",
                    width: Int(asset.size.width), height: Int(asset.size.height), url: file.map { "/media/\($0)" },
                    current: file != nil && inputs.sources.contains { $0.item == item && $0.video.url.lastPathComponent == file }))
            }
        }
        return (screenshots, videos, problems)
    }

    /// The size a platform's screenshots are framed at.
    func canvasSize(_ kind: Platform.Kind) -> CGSize {
        project.frames?.canvasSize(for: kind) ?? kind.screenshotSize
    }

    /// The strip a screenshot shows in: its platform's, or a custom page's on
    /// that platform.
    static func stripID(_ platform: Platform.Kind, page: String?) -> String {
        page.map { "page-\($0)-\(platform.rawValue)" } ?? platform.rawValue
    }

    /// The catalog as the last commit has it, or nothing outside git or
    /// before the first commit.
    func committed() async -> [String: [String: String]] {
        let path = project.metadata.catalog
        guard let data = try? await Shell.run("git show HEAD:'\(path)'", in: session.root),
              let catalog = try? JSONDecoder().decode(StringCatalog.self, from: data)
        else { return [:] }
        return catalog.strings.mapValues { entry in
            (entry.localizations ?? [:]).compactMapValues { $0.stringUnit?.value }
        }
    }

    func field(_ key: String, in copy: StoreCopy) throws -> Field {
        guard let field = copy.field(key) else { throw Stopped(description: "\(key) is not App Store copy") }
        return field
    }

    func locale(_ language: String) throws -> StoreLocale {
        guard let locale = project.locale(language) else { throw Stopped(description: "\(language) is not a configured locale") }
        return locale
    }

    /// An edit from the page counts as reviewed: a person wrote it.
    func set(_ value: String, key: String, language: String) throws {
        var copy = try session.copy()
        copy.set(value, field: try field(key, in: copy), locale: try locale(language))
        try copy.write(root: session.root)
    }

    func approve(key: String, language: String) throws {
        var copy = try session.copy()
        guard copy.approve(try field(key, in: copy), locale: try locale(language)) else {
            throw Stopped(description: "\(key) has no \(language) value to approve")
        }
        try copy.write(root: session.root)
    }

    /// What App Store Connect shows now, read-only.
    func live() async throws -> [String: [String: String]] {
        let platform = project.storePlatforms[0]
        let live = try await LiveCopy(project: project, asc: try session.connect(), platform: platform).read()
        return live.catalog.strings.mapValues { entry in
            (entry.localizations ?? [:]).compactMapValues { $0.stringUnit?.value }
        }
    }
}

extension Commands {
    /// Serves the review page on 127.0.0.1 and opens it in the browser.
    /// Runs until stopped.
    static func review(_ session: Session, open: Bool) async throws {
        try session.checkProject()
        let review = Review(session: session)
        let server = try HTTPServer { request in await review.handle(request) }
        let port = try await server.start()
        let url = "http://127.0.0.1:\(port)/"
        session.console.print("Reviewing \(session.project.metadata.catalog) at \(url)")
        session.console.print("Edits save to the catalog as you make them. Press Ctrl-C to stop.")
        if open { _ = try? await Shell.run("open '\(url)'", in: session.root) }
        while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
    }
}
