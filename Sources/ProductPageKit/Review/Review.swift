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
        /// The field it is about, when the message starts with its key.
        let key: String?
        /// The locale it is about, when the message names one after the
        /// key: `keywords · da: …`.
        let locale: String?
    }

    /// A part of the page, listed in its sidebar.
    struct Section: Codable, Equatable {
        enum Kind: String, Codable {
            /// Fields shown one under another.
            case copy
            /// One field per version, newest first, shown one at a time.
            case releases
            /// Strips of screenshots with their captions, after any fields.
            case screenshots
            /// A video with its caption's lines as the fields.
            case video
        }

        let id: String
        let group: String
        let title: String
        let kind: Kind
        /// Catalog keys.
        let fields: [String]
        var strips: [Strip] = []
        /// The video's kind, for a video.
        var video: String?
    }

    /// A platform's screenshots, or a custom page's on one platform.
    struct Strip: Codable, Equatable {
        let id: String
        let name: String
        let width: Int
        let height: Int
        /// Each position's caption lines, by catalog key; empty without a
        /// theme.
        let captions: [[String]]
    }

    let app: String
    let catalog: String
    /// Whether `/media/icon` serves the app icon.
    let icon: Bool
    let sourceLanguage: String
    /// Changes whenever the catalog file does.
    let revision: String
    let locales: [Locale]
    let fields: [FieldInfo]
    let values: [String: [String: Unit]]
    /// The values in the last commit, for "changed since".
    let committed: [String: [String: String]]
    let problems: [Issue]
    /// Every field is in one of them or in one of their strips.
    let sections: [Section]
}

/// The review page's API: read the copy, edit a value, approve a
/// translation, compare with App Store Connect.
actor Review {
    let session: Session

    init(session: Session) {
        self.session = session
    }

    /// A screenshot in one locale, framed as asked for, or why it could not be.
    struct Screenshot: Codable, Equatable {
        let locale: String
        let position: Int
        /// Nil when it could not be framed.
        let url: String?
        let problems: [String]
    }

    /// A video in one locale as last rendered, and what stops it rendering now.
    struct Video: Codable, Equatable {
        let kind: String
        let locale: String
        let width: Int
        let height: Int
        /// Nil until it is rendered.
        let url: String?
        /// False when its caption or captures changed since it was rendered.
        let current: Bool
        let problems: [String]
    }

    var project: Project { session.project }

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        do {
            switch (request.method, request.route) {
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
            case ("GET", "/api/live"):
                return .json(try await live())
            case ("GET", "/api/screenshots"):
                guard let strip = request.query("strip") else { throw Stopped(description: "name a strip of screenshots") }
                return .json(try await screenshots(strip: strip, locale: request.query("locale"),
                                                   position: request.query("position").flatMap { Int($0) }))
            case ("GET", "/api/videos"):
                guard let code = request.query("locale") else { throw Stopped(description: "name a locale") }
                return .json(try await videos(locale: try locale(code)))
            case ("GET", "/media/icon"):
                guard let icon = project.icon else { return .error(404, "the project has no icon") }
                return try .file(session.root.appending(path: icon), contentType: "image/png", range: nil)
            case ("GET", let path) where path.hasPrefix("/media/"):
                return try file(String(path.dropFirst("/media/".count)), range: request.headers["range"])
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
    func file(_ name: String, range: String?) throws -> HTTPServer.Response {
        let pattern = /[0-9a-f]{32}\.(png|jpg|mp4)/
        guard let match = name.wholeMatch(of: pattern) else { return .error(404, "no such file") }
        let type = ["png": "image/png", "jpg": "image/jpeg", "mp4": "video/mp4"][String(match.1)]!
        let directory = match.1 == "mp4" ? session.cache.videos : session.cache.framed
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .error(404, "no such file") }
        return try .file(url, contentType: type, range: range)
    }

    /// The copy and how the page lays it out. Screenshots and videos are
    /// asked for separately, a strip or a locale at a time, since framing
    /// every one takes far longer than reading the catalog.
    func state() async throws -> ReviewState {
        let copy = try session.copy()
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
            problems: copy.problems().map { issue($0, keys: copy.fields.map(\.key)) },
            sections: sections(copy)
        )
    }

    /// A check's result, with the field and locale its message starts with.
    func issue(_ problem: Problem, keys: [String]) -> ReviewState.Issue {
        let message = problem.message
        let key = keys.filter { message.hasPrefix($0 + " ") || message.hasPrefix($0 + ":") }.max { $0.count < $1.count }
        let locale = key.flatMap { key in
            project.locales.first { message.hasPrefix("\(key) · \($0.code):") }?.code
        }
        return ReviewState.Issue(severity: problem.severity == .error ? "error" : "warning", message: message, key: key, locale: locale)
    }

    /// The listing, What's New and the App Review notes, then the
    /// screenshots, each custom page, each treatment, and each video.
    func sections(_ copy: StoreCopy) -> [ReviewState.Section] {
        typealias Section = ReviewState.Section
        var sections = [
            Section(id: "listing", group: "Copy", title: "Product page", kind: .copy,
                    fields: [Field.name, .subtitle, .promotionalText, .description].map(\.key)),
            Section(id: "search", group: "Copy", title: "Search", kind: .copy, fields: [Field.keywords.key]),
            Section(id: "whats-new", group: "Copy", title: "What's New", kind: .releases,
                    fields: copy.fields.map(\.key).filter { Field.version(ofWhatsNew: $0) != nil }),
            Section(id: "app-review", group: "Copy", title: "App Review", kind: .copy,
                    fields: copy.fields.filter { [Field.reviewNotes, .productReviewNote].contains($0) }.map(\.key)),
        ]
        let platforms = project.platforms.filter { !$0.shots.isEmpty }
        if !platforms.isEmpty {
            sections.append(Section(id: "screenshots", group: "Screenshots", title: "App Store", kind: .screenshots, fields: [],
                                    strips: platforms.map { strip($0.kind, list: .store) }))
        }
        for page in project.customPages {
            sections.append(Section(id: "page-\(page.key)", group: "Custom pages", title: page.name, kind: .screenshots,
                                    fields: [page.promotionalText.key], strips: strips(of: page)))
        }
        for experiment in project.experiments {
            for treatment in experiment.treatments {
                sections.append(Section(id: "treatment-\(treatment.key)", group: "Experiments",
                                        title: "\(experiment.name) · \(treatment.name)", kind: .screenshots, fields: [],
                                        strips: strips(of: treatment)))
            }
        }
        for asset in project.videos?.assets ?? [] {
            let title = asset.kind.title
            sections.append(Section(id: "video-\(asset.kind.rawValue)", group: "Videos",
                                    title: title.prefix(1).uppercased() + title.dropFirst(), kind: .video,
                                    fields: Caption.Line.allCases.map { Field.caption(.video(asset.kind), $0).key },
                                    video: asset.kind.rawValue))
        }
        return sections
    }

    /// A page's or treatment's list on each platform it is framed on.
    func strips(of listing: some ShotListing) -> [ReviewState.Strip] {
        var kinds: [Platform.Kind] = []
        for subject in project.frameSubjects where subject.list == listing.list && !kinds.contains(subject.platform) {
            kinds.append(subject.platform)
        }
        return kinds.map { strip($0, list: listing.list) }
    }

    /// A list of shots on a platform, with each position's caption lines.
    func strip(_ kind: Platform.Kind, list: ShotList) -> ReviewState.Strip {
        let size = canvasSize(kind)
        let listing = project.listing(list, on: kind)
        return ReviewState.Strip(
            id: Self.stripID(kind, list: list), name: kind.name, width: Int(size.width), height: Int(size.height),
            captions: project.frames == nil ? [] : (listing?.shots ?? []).map { shot in
                Caption.Line.allCases.map { Field.caption(listing?.captionSubject(shot) ?? .screenshot(shot), $0).key }
            })
    }

    /// A strip's screenshots in one locale, or one position of it in every
    /// locale, framed so a caption edited here shows at once.
    func screenshots(strip: String, locale code: String?, position: Int?) async throws -> [Screenshot] {
        let subjects = project.frameSubjects.filter { Self.stripID($0.platform, list: $0.list) == strip }
        guard !subjects.isEmpty else { throw Stopped(description: "\(strip) is not a strip of screenshots") }
        let chosen: [FrameSubject]
        let locales: [StoreLocale]
        switch (code, position) {
        case (let code?, nil):
            (chosen, locales) = (subjects, [try locale(code)])
        case (nil, let position?) where subjects.indices.contains(position):
            (chosen, locales) = ([subjects[position]], project.locales)
        default:
            throw Stopped(description: "ask for a strip in one locale, or for one of its positions in every locale")
        }
        let report = try await frame(chosen, locales: locales)
        return locales.flatMap { locale in
            chosen.map { subject in
                let item = FramedItem(subject, locale: locale)
                return Screenshot(
                    locale: locale.code, position: subjects.firstIndex(of: subject)!,
                    url: report.screenshots.first { FramedItem($0.subject, locale: $0.locale) == item }
                        .map { "/media/\($0.url.lastPathComponent)" },
                    problems: report.problems.filter { $0.item == item }.map(\.reason))
            }
        }
    }

    /// The framing under way. One runs at a time, since each rewrites the
    /// cache's index and deletes the files it does not name.
    private var framing: Task<Void, Never>?

    func frame(_ subjects: [FrameSubject], locales: [StoreLocale]) async throws -> Framer.Report {
        let previous = framing
        let framer = Framer(copy: try session.copy(), cache: session.cache) { [console = session.console] in console.print($0) }
        let task = Task {
            await previous?.value
            return try await framer.frame(subjects, locales: locales)
        }
        framing = Task { _ = try? await task.value }
        return try await task.value
    }

    /// The videos in `locale` as last rendered. A video takes too long to
    /// render on every edit, so one whose inputs changed is marked out of
    /// date.
    func videos(locale: StoreLocale) async throws -> [Video] {
        guard let theme = project.videos else { return [] }
        let renderer = VideoRenderer(copy: try session.copy(), cache: session.cache, theme: theme) {
            [console = session.console] in console.print($0)
        }
        let inputs = try await renderer.sources(locales: [locale])
        let index = CacheIndex<VideoItem>.read(in: session.cache.videos)
        return theme.assets.map { asset in
            let item = VideoItem(kind: asset.kind, locale: locale)
            let file = index.file(for: item)
            return Video(
                kind: asset.kind.rawValue, locale: locale.code, width: Int(asset.size.width), height: Int(asset.size.height),
                url: file.map { "/media/\($0)" },
                current: file != nil && inputs.sources.contains { $0.item == item && $0.video.url.lastPathComponent == file },
                problems: inputs.problems.filter { $0.item == item }.map(\.reason))
        }
    }

    /// The size a platform's screenshots are framed at.
    func canvasSize(_ kind: Platform.Kind) -> CGSize {
        project.frames?.canvasSize(for: kind) ?? kind.screenshotSize
    }

    /// The strip a screenshot shows in: its platform's, or a custom page's or
    /// treatment's on that platform.
    static func stripID(_ platform: Platform.Kind, list: ShotList) -> String {
        list.folder.map { "\($0)-\(platform.rawValue)" } ?? platform.rawValue
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
