import ArgumentParser
import Foundation
import ProductPageKitASC
import ProductPageKitCore
import ProductPageKitRunner

/// The commands, each a thin layer over a function that takes a `Session`, so
/// tests run them without parsing a command line.
enum Commands {
    // MARK: - Metadata

    static func checkMetadata(_ session: Session) throws {
        try session.checkProject()
        let copy = try session.copy()
        let problems = copy.problems()
        for warning in problems.warnings { session.warn(warning.message) }
        try problems.check()
        let releases = copy.releases
        session.console.print("\(session.project.metadata.catalog) is ready: What's New for \(releases.isEmpty ? "no versions yet" : releases.joined(separator: ", ")).")
    }

    static func pushMetadata(_ session: Session, locales: String, platforms: String, options: WriteOptions) async throws {
        try session.checkProject()
        let copy = try session.copy()
        try copy.problems().check()
        let asc = try session.connect()
        let planner = MetadataPlanner(
            copy: copy,
            environment: session.environment,
            asc: asc,
            locales: try session.locales(locales),
            platforms: try session.storePlatforms(platforms)
        )
        try await session.execute(try await planner.plan(), asc: asc, options: options)
    }

    static func pullMetadata(_ session: Session, platform key: String?) async throws {
        try session.checkProject()
        let platform = try key.map { try session.storePlatforms($0)[0] } ?? session.project.storePlatforms[0]
        let live = try await LiveCopy(project: session.project, asc: try session.connect(), platform: platform).read()
        var copy = try session.copy()
        let changed = copy.merge(live)
        try copy.write(root: session.root)
        let file = session.project.metadata.catalog
        guard !changed.isEmpty else {
            session.console.print("\(file) already holds what App Store Connect has.")
            return
        }
        session.console.print("Wrote \(counted(changed.count, "value")) into \(file):")
        for value in changed { session.console.print("  \(value)") }
    }

    static func newRelease(_ session: Session, version: String) throws {
        try session.checkProject()
        var copy = try session.copy()
        try copy.addRelease(version)
        try copy.write(root: session.root)
        session.console.print("Added \(Field.whatsNew(version).key) to \(session.project.metadata.catalog), empty in every locale.")
    }

    // MARK: - Products

    static func catalogue(_ session: Session) async throws -> ProductCatalogue {
        let catalogue = try await ProductCatalogue.load(session.project, root: session.root)
        try catalogue.problems(project: session.project).check()
        return catalogue
    }

    static func checkProducts(_ session: Session) async throws {
        try session.checkProject()
        let catalogue = try await catalogue(session)
        let count = catalogue.subscriptionGroups.map(\.subscriptions.count).reduce(0, +)
        let purchases = catalogue.inAppPurchases.isEmpty ? "" : " and \(counted(catalogue.inAppPurchases.count, "in-app purchase"))"
        session.console.print("The catalogue is ready: \(counted(count, "subscription")) in \(counted(catalogue.subscriptionGroups.count, "group"))\(purchases).")
    }

    static func pushProducts(_ session: Session, options: WriteOptions) async throws {
        try session.checkProject()
        guard let products = session.project.products else { throw CatalogueError.notConfigured }
        let catalogue = try await catalogue(session)
        let copy = try session.copy()
        try copy.problems().check()
        let screenshot = try reviewScreenshot(session, .inAppPurchases)
        let asc = try session.connect()
        let planner = ProductsPlanner(
            project: session.project, products: products, catalogue: catalogue,
            reviewNote: copy.value(.productReviewNote, locale: session.project.primaryLocale),
            screenshot: screenshot, asc: asc
        )
        try await session.execute(try await planner.plan(), asc: asc, options: options)
    }

    /// The project's review screenshot of this kind, from the first platform
    /// that has captured one. Nil when the project takes none.
    static func reviewScreenshot(_ session: Session, _ kind: ReviewScreenshot.Kind) throws -> (name: String, data: Data)? {
        guard session.project.reviewScreenshots.contains(where: { $0.kind == kind }) else { return nil }
        for platform in session.project.platforms {
            let url = session.cache.review(platform, kind)
            if FileManager.default.fileExists(atPath: url.path) { return (url.lastPathComponent, try Data(contentsOf: url)) }
        }
        session.warn("there is no App Review screenshot of the \(kind.title) yet; `productpage screenshots capture` takes it")
        return nil
    }

    static func writeStoreKit(_ session: Session) async throws {
        try session.checkProject()
        let catalogue = try await catalogue(session)
        let changed = try StoreKitConfiguration.write(catalogue: catalogue, project: session.project, root: session.root)
        let path = session.project.products?.storeKit?.path ?? ""
        session.console.print(changed ? "Wrote \(path)." : "\(path) already matches the catalogue.")
    }

    // MARK: - Screenshots and videos

    @discardableResult
    static func captureScreenshots(_ session: Session, platforms: String, locales: String, shots: String,
                                   workers: Int?, force: Bool, dryRun: Bool) async throws -> CaptureReport? {
        try session.checkProject()
        if let workers, workers < 1 { throw Stopped(description: "--workers takes 1 or more.") }
        let project = session.project
        let request = CaptureRequest(
            platforms: try session.platforms(platforms),
            locales: try session.locales(locales),
            shots: shotList(shots),
            workers: workers,
            force: force
        )
        let plan = try CapturePlan(project: project, request: request, machine: .current)
        if dryRun {
            for line in plan.lines { session.console.print(line) }
            session.console.print("Dry run: nothing built or captured.")
            return nil
        }
        let console = session.console
        return try await ScreenshotRunner(project: project, root: session.root, cache: session.cache) { console.print($0) }
            .run(plan)
    }

    /// `inbox,library:pro`: scenes, each with an optional variant after a
    /// colon. Nil when empty.
    static func shotList(_ flag: String) -> [Shot]? {
        let shots = flag.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { item in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            return Shot(parts[0], variant: parts.count == 2 ? parts[1] : nil)
        }
        return shots.isEmpty ? nil : shots
    }

    static func doctor(_ session: Session) async throws {
        var checks = await Doctor(project: session.project, root: session.root).checks()
        do {
            _ = try Credentials(environment: session.environment)
            checks.append(DoctorCheck(.ok, "App Store Connect credentials are set"))
        } catch {
            checks.append(DoctorCheck(.failed, "App Store Connect credentials: \(error)"))
        }
        for check in checks {
            session.console.print(check.status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0) + check.message)
        }
        guard !checks.contains(where: { $0.status == .failed }) else { throw ExitCode.failure }
    }

    /// Frames every listed shot of `platforms` in `locales`, in the lists
    /// `lists` takes, into the cache, and stops when any could not be framed.
    @discardableResult
    static func frameScreenshots(_ session: Session, platforms: [Platform], locales: [StoreLocale],
                                 lists: (ShotList) -> Bool = { _ in true }) async throws -> Framer.Report {
        let console = session.console
        let report = try await Framer(copy: try session.copy(), cache: session.cache) { console.print($0) }
            .frame(platforms: platforms, locales: locales, lists: lists)
        guard report.problems.isEmpty else {
            throw Stopped(description: "Not every screenshot could be framed:\n" + report.problems.map { "  \($0)" }.joined(separator: "\n")
                          + "\n`productpage screenshots capture` takes the captures; the catalog holds the captions.")
        }
        announce(session, untranslated: report.untranslated, in: "frame", done: report.drawn, of: report.screenshots.count,
               noun: "screenshot", verb: "framed")
        return report
    }

    /// Renders the videos in `locales` into the cache.
    @discardableResult
    static func renderVideos(_ session: Session, locales: [StoreLocale]) async throws -> VideoRenderer.Report {
        let console = session.console
        let report = try await VideoRenderer(copy: try session.copy(), cache: session.cache, theme: try session.motionTheme()) {
            console.print($0)
        }.render(locales: locales) { console.print($0) }
        announce(session, untranslated: report.untranslated, in: "video", done: report.drawn, of: report.videos.count,
               noun: "video", verb: "rendered")
        return report
    }

    /// Warns of each caption line shown in the source language, then says
    /// what was drawn: `Framed 2 screenshots; 8 were already framed.`
    static func announce(_ session: Session, untranslated: [String], in medium: String, done: Int, of count: Int, noun: String,
                       verb: String) {
        for line in Set(untranslated).sorted() { session.warn("\(line) is not translated, so the \(medium) shows the source language") }
        let kept = count - done
        if done == 0 {
            session.console.print("\(counted(count, noun)) already \(verb).")
            return
        }
        let sentence = "\(verb.prefix(1).uppercased())\(verb.dropFirst()) \(counted(done, noun))"
        session.console.print(kept == 0 ? sentence + "." : sentence + "; \(kept) \(kept == 1 ? "was" : "were") already \(verb).")
    }

    /// Frames, then makes every set hold exactly the framed screenshots.
    static func pushScreenshots(_ session: Session, platforms: String, locales: String, options: WriteOptions) async throws {
        try session.checkProject()
        let platforms = try session.platforms(platforms)
        let locales = try session.locales(locales)
        let report = try await frameScreenshots(session, platforms: platforms, locales: locales, lists: { $0 == .store })
        let asc = try session.connect()
        let planner = ScreenshotsPlanner(copy: try session.copy(), screenshots: report.screenshots, platforms: platforms,
                                         locales: locales, asc: asc)
        try await session.execute(try await planner.plan(), asc: asc, options: options)
    }

    /// Frames, then makes each custom page hold its copy, keywords and
    /// screenshots.
    static func pushPages(_ session: Session, pages: String, platforms: String, locales: String, options: WriteOptions) async throws {
        try session.checkProject()
        let pages = try session.pages(pages)
        guard !pages.isEmpty else { throw Stopped(description: "The project has no custom pages (Project.customPages).") }
        let copy = try session.copy()
        try copy.problems().check()
        let platforms = try session.platforms(platforms)
        let locales = try session.locales(locales)
        let report = try await frameScreenshots(session, platforms: platforms, locales: locales, lists: Set(pages.map(\.list)).contains)
        let asc = try session.connect()
        let planner = CustomPagesPlanner(copy: copy, screenshots: report.screenshots, pages: pages, platforms: platforms.map(\.kind),
                                         locales: locales, asc: asc)
        try await session.execute(try await planner.plan(), asc: asc, options: options)
    }

    /// Frames, then makes each experiment hold its treatments' screenshots in
    /// every locale. Never starts an experiment or submits it for review.
    static func pushExperiments(_ session: Session, experiments: String, locales: String, options: WriteOptions) async throws {
        try session.checkProject()
        let experiments = try session.experiments(experiments)
        guard !experiments.isEmpty else { throw Stopped(description: "The project has no experiments (Project.experiments).") }
        try session.copy().problems().check()
        let locales = try session.locales(locales)
        let report = try await frameScreenshots(session, platforms: session.project.platforms, locales: locales,
                                                lists: Set(experiments.flatMap(\.treatments).map(\.list)).contains)
        let asc = try session.connect()
        let planner = ExperimentsPlanner(project: session.project, experiments: experiments, screenshots: report.screenshots,
                                         locales: locales, asc: asc)
        try await session.execute(try await planner.plan(), asc: asc, options: options)
    }

    /// Renders, then uploads the changed videos and places them.
    static func pushVideos(_ session: Session, locales: String, options: WriteOptions,
                           pollInterval: Duration = .seconds(10)) async throws {
        try session.checkProject()
        let report = try await renderVideos(session, locales: try session.locales(locales))
        let asc = try session.connect()
        let planner = VideosPlanner(project: session.project, videos: report.videos, motion: try session.motionTheme().motion, asc: asc,
                                    pollInterval: pollInterval)
        try await session.execute(try await planner.plan(), asc: asc, options: options)
    }
}

// MARK: - Command line

struct MetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "The product page's text, from the String Catalog.",
        subcommands: [Check.self, Push.self, Pull.self]
    )

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check the copy against App Store Connect's limits. No network.")
        func run() async throws { try Commands.checkMetadata(try Session.get()) }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make App Store Connect's editable versions match the copy.")
        @OptionGroup var locales: LocaleFlag
        @Option(help: "Comma-separated: ios, macos, tvos, visionos. Default: all.") var platforms = ""
        @OptionGroup var options: WriteOptions

        func run() async throws {
            try await Commands.pushMetadata(try Session.get(), locales: locales.locales, platforms: platforms, options: options)
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write App Store Connect's text into the catalog, What's New for every version included."
        )
        @Option(help: "The platform whose versions to read. Default: the first configured.") var platform: String?

        func run() async throws { try await Commands.pullMetadata(try Session.get(), platform: platform) }
    }
}

struct ReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release", abstract: "What's New.", subcommands: [New.self])

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add What's New for a version to the catalog, empty in every locale.")
        @Argument(help: "The version, as App Store Connect spells it: 1.9, 1.9.1.") var version: String
        func run() async throws { try Commands.newRelease(try Session.get(), version: version) }
    }
}

struct ProductsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "products",
        abstract: "Subscriptions and in-app purchases, from the product catalogue.",
        subcommands: [Check.self, Push.self, StoreKit.self]
    )

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check the catalogue. No network.")
        func run() async throws { try await Commands.checkProducts(try Session.get()) }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make App Store Connect's subscriptions and in-app purchases match the catalogue.")
        @OptionGroup var options: WriteOptions
        func run() async throws { try await Commands.pushProducts(try Session.get(), options: options) }
    }

    struct StoreKit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "storekit", abstract: "Write the StoreKit configuration file from the catalogue.")
        func run() async throws { try await Commands.writeStoreKit(try Session.get()) }
    }
}

struct ScreenshotsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "screenshots", abstract: "App Store screenshots.",
                                                    subcommands: [Capture.self, Frame.self, Edit.self, Push.self])

    struct Capture: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build the app and capture each platform's shots in every locale, into the cache."
        )
        @OptionGroup var platforms: PlatformFlag
        @OptionGroup var locales: LocaleFlag
        @Option(help: "Comma-separated scenes, `scene:variant` for a variant. Default: each platform's shots and the App Review screenshots.")
        var shots = ""
        @Option(help: "Simulators per platform at once, the one for screens tests put up included. Default: one for every four cores and every 4 GB of memory past 8, at most one per locale and one for the tests' screens.") var workers: Int?
        @Flag(help: "Take every capture again. By default one taken from the same app, device and settings is kept.") var force = false
        @Flag(help: "Print what would be captured and stop.") var dryRun = false

        func run() async throws {
            let session = try Session.get()
            let (platforms, locales, shots, workers, force, dryRun) = (platforms.platforms, locales.locales, shots, workers, force, dryRun)
            _ = try await cancellingOnInterrupt {
                try await Commands.captureScreenshots(session, platforms: platforms, locales: locales, shots: shots,
                                                      workers: workers, force: force, dryRun: dryRun)
            }
        }
    }

    struct Frame: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Frame the captures with the project's theme, into the cache.")
        @OptionGroup var platforms: PlatformFlag
        @OptionGroup var locales: LocaleFlag

        func run() async throws {
            let session = try Session.get()
            try session.checkProject()
            try await Commands.frameScreenshots(session, platforms: try session.platforms(platforms.platforms),
                                                locales: try session.locales(locales.locales))
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Edit the frames' layouts in the browser, in the theme's editor.")
        @Flag(help: "Print the address without opening the browser.") var noOpen = false

        func run() async throws { try await Commands.editFrames(try Session.get(), open: !noOpen) }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Frame, then make each screenshot set hold exactly the framed screenshots, uploading only changed ones."
        )
        @OptionGroup var platforms: PlatformFlag
        @OptionGroup var locales: LocaleFlag
        @OptionGroup var options: WriteOptions

        func run() async throws {
            try await Commands.pushScreenshots(try Session.get(), platforms: platforms.platforms, locales: locales.locales, options: options)
        }
    }
}

struct VideosCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "videos", abstract: "Product page header and search result videos.",
                                                    subcommands: [Render.self, Push.self])

    struct Render: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Render the videos from the captures, into the cache.")
        @OptionGroup var locales: LocaleFlag

        func run() async throws {
            let session = try Session.get()
            try session.checkProject()
            let locales = try session.locales(locales.locales)
            _ = try await cancellingOnInterrupt { try await Commands.renderVideos(session, locales: locales) }
        }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Render, then upload changed videos and place them on the editable iOS version.")
        @OptionGroup var locales: LocaleFlag
        @OptionGroup var options: WriteOptions

        func run() async throws { try await Commands.pushVideos(try Session.get(), locales: locales.locales, options: options) }
    }
}

struct PagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pages", abstract: "Custom product pages.", subcommands: [Push.self])

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Frame, then make each custom page hold its promotional text, keywords and screenshots. Never submits for review."
        )
        @Option(help: "Comma-separated page keys. Default: all.") var pages = ""
        @OptionGroup var platforms: PlatformFlag
        @OptionGroup var locales: LocaleFlag
        @OptionGroup var options: WriteOptions

        func run() async throws {
            try await Commands.pushPages(try Session.get(), pages: pages, platforms: platforms.platforms, locales: locales.locales,
                                         options: options)
        }
    }
}

struct ExperimentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "experiments", abstract: "Product page optimization experiments.",
                                                    subcommands: [Push.self])

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Frame, then make each experiment hold its treatments' screenshots in every locale. Never starts an experiment or submits it for review."
        )
        @Option(help: "Comma-separated experiment keys. Default: all.") var experiments = ""
        @OptionGroup var locales: LocaleFlag
        @OptionGroup var options: WriteOptions

        func run() async throws {
            try await Commands.pushExperiments(try Session.get(), experiments: experiments, locales: locales.locales, options: options)
        }
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check Xcode, the simulators, Screen Recording and the App Store Connect credentials."
    )

    func run() async throws { try await Commands.doctor(try Session.get()) }
}

struct ReviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Review and edit the App Store copy in the browser, beside what changed and what is live."
    )
    @Flag(help: "Print the address without opening the browser.") var noOpen = false

    func run() async throws { try await Commands.review(try Session.get(), open: !noOpen) }
}
