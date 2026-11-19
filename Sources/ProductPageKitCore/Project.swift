public import Foundation
public import ProductPageKitFrames

/// One app's product page: what it is, where its docs and files are, and how
/// its in-app products are defined. Each app's tools executable declares one
/// and passes it to `ProductPageKit.main`.
///
/// Paths are relative to the repository root.
public struct Project: Sendable {
    /// The app's name, as the commands print it and as uploaded videos are named.
    public var name: String
    public var bundleID: String
    /// The app's Xcode project, for capturing screenshots and archiving.
    public var xcode: XcodeProject?
    /// The first is the primary locale: the one fields App Store Connect does
    /// not localize are written in.
    public var locales: [StoreLocale]
    /// Every capture's appearance and text size, whatever the machine and the
    /// simulators were left in.
    public var appearance: Appearance
    public var contentSize: ContentSize
    /// What a simulator's status bar clock shows.
    public var statusBarTime: StatusBarTime
    /// The language and region the simulators run in.
    public var simulatorLocale: SimulatorLocale
    /// What a capture run leaves of its build.
    public var build: BuildRetention
    /// The devices the product page shows, each with its shots. Their App
    /// Store platforms are the versions metadata is written to.
    public var platforms: [Platform]
    /// App Review screenshots drawn by tests, captured on every platform.
    public var reviewScreenshots: [ReviewScreenshot]
    /// How screenshots are framed. Without a theme, the captures are the
    /// screenshots, and must be a size App Store Connect takes.
    public var frames: (any FrameTheme)?
    /// The product page header and search result videos.
    public var videos: (any MotionTheme)?
    /// Pages with their own screenshots, promotional text and keywords.
    public var customPages: [CustomPage]
    /// Product page optimization tests, each with its treatments' screenshots.
    public var experiments: [Experiment]
    /// Files the app reads while it is captured, which themes may draw too.
    public var files: (any CaptureFiles)?
    /// Images of the app for elsewhere, taken in the primary locale.
    public var renders: [Render]
    /// The format framed screenshots are written and uploaded in.
    public var output: ImageFormat
    /// The app icon, a 1024 px PNG, which the review page shows.
    public var icon: String?
    public var metadata: Metadata
    public var products: Products?
    /// TestFlight uploads.
    public var builds: Builds?
    /// The Android app the Android platforms are captured from.
    public var android: AndroidApp?
    /// The Google Play listing, which the Android platforms and graphics
    /// and the `play.` copy are published to.
    public var play: GooglePlay?

    public init(
        name: String,
        bundleID: String,
        xcode: XcodeProject? = nil,
        locales: [StoreLocale],
        appearance: Appearance = .light,
        contentSize: ContentSize = .large,
        statusBarTime: StatusBarTime = .nineFortyOne,
        simulatorLocale: SimulatorLocale = .primary,
        build: BuildRetention = .keep,
        platforms: [Platform],
        reviewScreenshots: [ReviewScreenshot] = [],
        frames: (any FrameTheme)? = nil,
        videos: (any MotionTheme)? = nil,
        customPages: [CustomPage] = [],
        experiments: [Experiment] = [],
        files: (any CaptureFiles)? = nil,
        renders: [Render] = [],
        output: ImageFormat = .png,
        icon: String? = nil,
        metadata: Metadata,
        products: Products? = nil,
        builds: Builds? = nil,
        android: AndroidApp? = nil,
        play: GooglePlay? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.xcode = xcode
        self.locales = locales
        self.appearance = appearance
        self.contentSize = contentSize
        self.statusBarTime = statusBarTime
        self.simulatorLocale = simulatorLocale
        self.build = build
        self.platforms = platforms
        self.reviewScreenshots = reviewScreenshots
        self.frames = frames
        self.videos = videos
        self.customPages = customPages
        self.experiments = experiments
        self.files = files
        self.renders = renders
        self.output = output
        self.icon = icon
        self.metadata = metadata
        self.products = products
        self.builds = builds
        self.android = android
        self.play = play
    }

    public var primaryLocale: StoreLocale { locales[0] }

    /// The App Store platforms the configured devices belong to, in order.
    public var storePlatforms: [StorePlatform] {
        var seen: [StorePlatform] = []
        for platform in platforms.compactMap(\.storePlatform) where !seen.contains(platform) {
            seen.append(platform)
        }
        return seen
    }

    /// The configured platforms whose screenshots go to `store`.
    public func platforms(in store: Store) -> [Platform] {
        platforms.filter { $0.store == store }
    }

    /// The App Store platforms builds are archived for: those `builds`
    /// names, or else the product page's.
    public var buildPlatforms: [StorePlatform] { builds?.platforms ?? storePlatforms }

    public func locale(_ code: String) -> StoreLocale? {
        locales.first { $0.code == code }
    }

    public func platform(_ kind: Platform.Kind) -> Platform? {
        platforms.first { $0.kind == kind }
    }

    public func customPage(_ key: String) -> CustomPage? {
        customPages.first { $0.key == key }
    }

    /// The treatment with this key, in whichever experiment has it.
    public func treatment(_ key: String) -> Treatment? {
        experiments.lazy.flatMap(\.treatments).first { $0.key == key }
    }

    /// The shots a list shows on `platform`, or nil for a list the project
    /// does not have.
    public func listing(_ list: ShotList, on platform: Platform.Kind) -> (any ShotListing)? {
        switch list {
        case .store: self.platform(platform)
        case .customPage(let key): customPage(key)
        case .treatment(let key): treatment(key)
        }
    }

    /// The configured platforms App Store Connect takes a custom page's or a
    /// treatment's screenshots for.
    public var alternatePlatforms: [Platform.Kind] {
        Platform.Kind.alternateScreenshotPlatforms.filter { platform($0) != nil }
    }

    /// What has a caption: every listed shot once a theme frames them, each
    /// custom page's and treatment's shots that do not show the store's
    /// caption, and every video.
    public var captionSubjects: [CaptionSubject] {
        var subjects: [CaptionSubject] = []
        if frames != nil {
            for shot in platforms.flatMap(\.shots) where !subjects.contains(.screenshot(shot)) {
                subjects.append(.screenshot(shot))
            }
            let listings: [any ShotListing] = customPages + experiments.flatMap(\.treatments)
            for listing in listings {
                subjects += listing.captionedShots.map(listing.list.captionSubject)
            }
        }
        subjects += (videos?.assets ?? []).map { .video($0.kind) }
        return subjects
    }

    /// Every screenshot framed: each platform's list, then each custom
    /// page's shots on its configured platforms that take them, then each
    /// treatment's.
    public var frameSubjects: [FrameSubject] {
        func subjects(of listing: some ShotListing, on kinds: [Platform.Kind]) -> [FrameSubject] {
            kinds.flatMap { kind in listing.shots.map { FrameSubject($0, on: kind, list: listing.list) } }
        }
        return platforms.flatMap { subjects(of: $0, on: [$0.kind]) }
            + customPages.flatMap { page in
                subjects(of: page, on: page.platforms.filter(alternatePlatforms.contains))
            }
            + experiments.flatMap(\.treatments).flatMap { subjects(of: $0, on: alternatePlatforms) }
    }

    /// What `frame` is drawn from: what the theme says, or, without one, the
    /// shot's own capture, which is then the screenshot.
    public func sources(for frame: FrameSubject) -> [FrameSource] {
        frames?.sources(for: frame) ?? [.capture(frame.shot, on: frame.platform)]
    }

    /// The scenes captured on `platform`: those the frames and videos draw
    /// from, in the order they are first drawn.
    public func captures(on platform: Platform.Kind) -> [Shot] {
        var shots: [Shot] = []
        func add(_ shot: Shot) { if !shots.contains(shot) { shots.append(shot) } }
        for frame in frameSubjects {
            for source in sources(for: frame) {
                if case .capture(let shot, platform) = source.content { add(shot) }
            }
        }
        for layer in videos?.assets.flatMap(\.devices) ?? [] where layer.platform == platform {
            layer.captures.forEach(add)
        }
        return shots
    }

    /// The components exported on `platform` for the frames, in the order
    /// they are first drawn.
    public func components(on platform: Platform.Kind) -> [Component] {
        var components: [Component] = []
        for frame in frameSubjects {
            for source in sources(for: frame) {
                if case .component(let component, platform) = source.content, !components.contains(component) {
                    components.append(component)
                }
            }
        }
        return components
    }

    /// The scenes captured on `platform` for renders alone, in the primary
    /// locale.
    public func renderCaptures(on platform: Platform.Kind) -> [Shot] {
        let drawn = Set(captures(on: platform))
        var shots: [Shot] = []
        for render in renders {
            if case .capture(let shot, platform) = render.source, !drawn.contains(shot), !shots.contains(shot) {
                shots.append(shot)
            }
        }
        return shots
    }

    /// The screens tests put up on `platform` for renders, in the primary
    /// locale.
    public func renderTests(on platform: Platform.Kind) -> [TestCapture] {
        var tests: [TestCapture] = []
        for render in renders {
            if case .test(let test, platform) = render.source, !tests.contains(test) { tests.append(test) }
        }
        return tests
    }

    /// The components exported on `platform` for renders alone, in the
    /// primary locale.
    public func renderComponents(on platform: Platform.Kind) -> [Component] {
        let drawn = Set(components(on: platform))
        var components: [Component] = []
        for render in renders {
            if case .component(let component, platform) = render.source, !drawn.contains(component),
               !components.contains(component) {
                components.append(component)
            }
        }
        return components
    }

    /// Problems with the configuration itself, before any doc is read.
    public func problems() -> [String] {
        var problems: [String] = []
        if locales.isEmpty { problems.append("no locales") }
        let codes = locales.map(\.code)
        for code in codes.repeated {
            problems.append("locale \(code) is listed twice")
        }
        if platforms.isEmpty { problems.append("no platforms") }
        let ids = platforms.map(\.id)
        for id in ids.repeated {
            problems.append("platform \(id) is listed twice")
        }
        if let videos {
            if !platforms.contains(where: { $0.storePlatform == .iOS }), !videos.assets.isEmpty {
                problems.append("header and search videos go on the iOS version, and no iOS platform is configured")
            }
            problems += videos.problems(platforms: platforms, files: Set(files?.names ?? []))
        }
        let pageKeys = customPages.map(\.key)
        for key in pageKeys.repeated {
            problems.append("the \(key) page is listed twice")
        }
        let pageNames = customPages.map(\.name)
        for name in pageNames.repeated {
            problems.append("two custom pages are named \(name)")
        }
        let storeShots = Set(platforms.flatMap(\.shots))
        problems += customPages.flatMap { $0.problems(platforms: platforms, storeShots: storeShots) }
        let experimentKeys = experiments.map(\.key)
        for key in experimentKeys.repeated {
            problems.append("the \(key) experiment is listed twice")
        }
        let experimentNames = experiments.map(\.name)
        for name in experimentNames.repeated {
            problems.append("two experiments are named \(name)")
        }
        let treatmentKeys = experiments.flatMap(\.treatments).map(\.key)
        for key in treatmentKeys.repeated {
            problems.append("the \(key) treatment is listed twice")
        }
        problems += experiments.flatMap { $0.problems(platforms: platforms, storeShots: storeShots) }
        if let frames {
            for platform in platforms where !platform.kind.accepts(frames.canvasSize(for: platform.kind)) {
                let size = frames.canvasSize(for: platform.kind)
                problems.append("the theme draws \(platform.name) screenshots at \(Int(size.width)) × \(Int(size.height)), which \(platform.store.name) does not take")
            }
        }
        problems += androidProblems()
        let fileNames = Set(files?.names ?? [])
        for frame in frameSubjects {
            for source in sources(for: frame) {
                switch source.content {
                case .capture(_, let platform), .component(_, let platform):
                    if let drawn = self.platform(platform) {
                        // Without a theme, the graphic's own problem says so.
                        if case .drawn = drawn.capture, frames != nil {
                            problems.append("the \(frame.platform.name) \(frame.shot) screenshot draws \(source), and the \(platform.name) is drawn, not captured")
                        }
                    } else {
                        problems.append("the \(frame.platform.name) \(frame.shot) screenshot draws \(source), and the \(platform.name) is not a configured platform")
                    }
                case .file(let name):
                    if !fileNames.contains(name) {
                        problems.append("the \(frame.platform.name) \(frame.shot) screenshot draws \(source), which the project's capture files do not include")
                    }
                }
            }
        }
        // Exported under each platform, so a name is one platform's once.
        for platform in Set(renders.map(\.source.platform)) {
            let names = renders.filter { $0.source.platform == platform }.map(\.name)
            for name in names.repeated {
                problems.append("the \(platform.name) render \(name) is listed twice")
            }
        }
        for render in renders {
            if render.name.isEmpty || render.name.contains("/") {
                problems.append("the render \"\(render.name)\" needs a name that is a file name")
            }
            if self.platform(render.source.platform) == nil {
                problems.append("the render \(render.name) is on the \(render.source.platform.name), which is not a configured platform")
            }
        }
        if case .jpeg(let quality) = output, !(0...1).contains(quality) {
            problems.append("JPEG quality is \(quality), and it runs from 0 to 1")
        }
        problems += platforms.flatMap { $0.problems() }
        let kinds = reviewScreenshots.map(\.kind)
        for kind in kinds.repeated {
            problems.append("the \(kind.title) review screenshot is listed twice")
        }
        if builds != nil {
            if xcode == nil { problems.append("builds are archived from the Xcode project, and none is configured") }
            if buildPlatforms.isEmpty { problems.append("builds name no platforms") }
            for platform in buildPlatforms.map(\.name).repeated {
                problems.append("builds list \(platform) twice")
            }
        }
        return problems.sorted()
    }
}

extension Project {
    /// Problems with the Android app, the Google Play listing and the
    /// platforms they serve.
    func androidProblems() -> [String] {
        var problems: [String] = []
        let playPlatforms = platforms(in: .googlePlay)
        if play == nil, !playPlatforms.isEmpty {
            problems.append("the \(playPlatforms.map(\.name).joined(separator: ", ")) \(playPlatforms.count == 1 ? "goes" : "go") to Google Play, and Project.play is not set")
        }
        let captured = platforms.filter { if case .android = $0.capture { true } else { false } }
        let appless = captured.filter { androidApp(for: $0) == nil }
        if !appless.isEmpty {
            problems.append("the \(appless.map(\.name).joined(separator: ", ")) \(appless.count == 1 ? "is" : "are") captured on Android, and Project.android is not set")
        }
        for platform in captured where !renderTests(on: platform.kind).isEmpty {
            problems.append("the \(platform.name) runs no tests, and a render asks one for a screen")
        }
        if frames == nil {
            for platform in platforms {
                if case .drawn = platform.capture { problems.append("the \(platform.name) is drawn by a theme, and the project has none") }
            }
        }
        if let android { problems += android.problems(owner: "Project.android") }
        for platform in captured {
            if case .android(_, let app?) = platform.capture { problems += app.problems(owner: "the \(platform.name)'s app") }
        }
        if let play {
            if play.packageName.isEmpty { problems.append("Project.play names no package") }
            for locale in locales where locale.playLanguage == nil {
                problems.append("locale \(locale.code) is App Store Connect's \(locale.store), which has no Google Play language")
            }
            let languages = locales.compactMap(\.playLanguage)
            for language in languages.repeated {
                let codes = locales.filter { $0.playLanguage == language }.map(\.code)
                problems.append("locales \(codes.joined(separator: " and ")) are both Google Play's \(language)")
            }
        }
        return problems
    }

    /// The app `platform` is captured from: its own, or `android`. Nil for a
    /// platform not captured on Android.
    public func androidApp(for platform: Platform) -> AndroidApp? {
        guard case .android(_, let app) = platform.capture else { return nil }
        return app ?? android
    }
}

/// An Android app the Android platforms are captured from. A capture
/// installs the APK, then starts `activity` once for each scene with the
/// scene's name in the `productPageScene` extra and its variant, if any, in
/// `productPageVariant`, and once for each component with its name in
/// `productPageComponent` and its state in `productPageComponentState`. The
/// app logs `ready <scene>`, or `ready <component>[@<state>]`, under the tag
/// `ProductPage` once it is on screen and holds still, followed by the rects
/// of what it marked: a scene's highlights, or the component's bounds.
public struct AndroidApp: Hashable, Sendable {
    /// Shell commands run at the repository root that build the APK, such as
    /// `./gradlew :app:assembleDebug`.
    public var build: [String]
    /// The APK they write, relative to the repository root.
    public var apk: String
    /// The application id the APK installs as: the debug build's, such as
    /// `com.example.app.dev`.
    public var applicationID: String
    /// The activity started with each scene, as `am start` names it within
    /// the app: `.MainActivity`, or a whole class name.
    public var activity: String

    public init(build: [String], apk: String, applicationID: String, activity: String) {
        self.build = build
        self.apk = apk
        self.applicationID = applicationID
        self.activity = activity
    }

    /// The component `am start` launches: `com.example.app.dev/.MainActivity`.
    public var component: String { "\(applicationID)/\(activity)" }

    func problems(owner: String) -> [String] {
        var problems: [String] = []
        if apk.isEmpty { problems.append("\(owner) names no APK") }
        if applicationID.isEmpty { problems.append("\(owner) names no application id") }
        if activity.isEmpty { problems.append("\(owner) names no activity") }
        return problems
    }
}

/// The app's Google Play listing.
public struct GooglePlay: Sendable {
    /// The listing's package name: the release build's application id.
    public var packageName: String
    /// False for a Play Console that sends changes for review only from its
    /// Publishing overview, which refuses an edit committed any other way;
    /// a push then leaves the committed changes there to send.
    public var sendsForReview: Bool

    public init(packageName: String, sendsForReview: Bool = true) {
        self.packageName = packageName
        self.sendsForReview = sendsForReview
    }
}

/// Text metadata: where the copy is, and the values that are the same in
/// every locale.
public struct Metadata: Sendable {
    /// The String Catalog holding the App Store copy.
    public var catalog: String
    public var urls: URLs
    public var copyright: String
    /// URLs a field must contain in every locale. App Review rejects a
    /// subscription app whose description does not link its terms of use.
    public var requiredLinks: [Field: [String]]
    /// Keywords for a locale without translated ones, so a new localization
    /// never goes live with none and drops out of search in its storefront.
    public var fallbackKeywords: String?
    public var reviewAccount: ReviewAccount?
    public var reviewContact: ReviewContact?

    public init(
        catalog: String = "AppStore.xcstrings",
        urls: URLs,
        copyright: String,
        requiredLinks: [Field: [String]] = [:],
        fallbackKeywords: String? = nil,
        reviewAccount: ReviewAccount? = nil,
        reviewContact: ReviewContact? = nil
    ) {
        self.catalog = catalog
        self.urls = urls
        self.copyright = copyright
        self.requiredLinks = requiredLinks
        self.fallbackKeywords = fallbackKeywords
        self.reviewAccount = reviewAccount
        self.reviewContact = reviewContact
    }

    /// Apple's standard licence agreement, for a description that has to link
    /// terms of use and has no custom EULA.
    public static let appleEULA = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
}

public struct URLs: Sendable {
    public var marketing: String
    public var support: String
    public var privacy: String

    public init(marketing: String, support: String, privacy: String) {
        self.marketing = marketing
        self.support = support
        self.privacy = privacy
    }
}

/// The account App Review signs in with, read from the environment so a
/// credential never sits in the repository.
public struct ReviewAccount: Sendable {
    public let nameVariable: String
    public let passwordVariable: String

    public static func environment(name: String, password: String) -> ReviewAccount {
        ReviewAccount(nameVariable: name, passwordVariable: password)
    }
}

/// Who App Review calls: `<prefix>FIRST_NAME`, `LAST_NAME`, `PHONE`, `EMAIL`.
public struct ReviewContact: Sendable {
    public let prefix: String

    public static func environment(prefix: String) -> ReviewContact {
        ReviewContact(prefix: prefix)
    }

    /// API attribute to environment variable.
    public var variables: [(attribute: String, variable: String)] {
        [
            ("contactFirstName", prefix + "FIRST_NAME"),
            ("contactLastName", prefix + "LAST_NAME"),
            ("contactPhone", prefix + "PHONE"),
            ("contactEmail", prefix + "EMAIL"),
        ]
    }
}

/// The Xcode project or workspace the app builds from.
public struct XcodeProject: Sendable {
    public enum Container: Sendable {
        case project(String)
        case workspace(String)
    }

    public var container: Container
    public var scheme: String
    /// Shell commands run at the repository root before building, such as the
    /// one that generates the project.
    public var before: [String]

    public static func project(_ path: String, scheme: String, before: [String] = []) -> XcodeProject {
        XcodeProject(container: .project(path), scheme: scheme, before: before)
    }

    public static func workspace(_ path: String, scheme: String, before: [String] = []) -> XcodeProject {
        XcodeProject(container: .workspace(path), scheme: scheme, before: before)
    }

    public var path: String {
        switch container {
        case .project(let path), .workspace(let path): path
        }
    }
}

public enum Appearance: String, Sendable {
    case light
    case dark
}

/// What a simulator's status bar clock shows.
public enum StatusBarTime: Sendable, Equatable {
    /// 9:41, as Apple's own screenshots show.
    case nineFortyOne
    /// The minute the run started, in every shot of it, for an app that
    /// shows the time of day itself, such as a programme guide, which the
    /// clock then agrees with.
    case captureStart
}

/// The language and region a simulator runs in. The app always runs in the
/// locale it captures, which it is given at launch; this sets the rest: the
/// status bar's clock, and any screen the system draws.
public enum SimulatorLocale: Sendable, Equatable {
    /// The primary locale, for every capture. A simulator never restarts to
    /// change locale, so a run is quicker.
    case primary
    /// The locale being captured, so the clock reads 9:41 in `en` and 09.41
    /// in `da`. An iPhone moves in place in a few seconds; an iPad, whose
    /// status bar shows the date, reboots.
    case captured
}

/// What a capture run leaves of its build, the largest part of the cache.
public enum BuildRetention: Sendable, Equatable {
    /// Kept, so the next run builds only what changed.
    case keep
    /// Deleted when the run ends, so the disk holds only captures and what
    /// is drawn from them; the next run builds from scratch.
    case deleteAfterRun
}

/// Dynamic Type sizes, as `simctl ui content_size` names them.
public enum ContentSize: String, CaseIterable, Sendable {
    case extraSmall = "extra-small"
    case small
    case medium
    case large
    case extraLarge = "extra-large"
    case extraExtraLarge = "extra-extra-large"
    case extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium"
    case accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"
}

/// An App Review screenshot a test draws, because the screen needs something
/// only a test bundle has. The test reports ready through a
/// `CaptureDirector<ReviewScene>` and returns when the runner says quit.
public struct ReviewScreenshot: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// The subscription screen, which every in-app purchase carries.
        case inAppPurchases

        public var title: String {
            switch self {
            case .inAppPurchases: "in-app purchases"
            }
        }
    }

    public let kind: Kind
    /// As `xcodebuild -only-testing:` takes it: `AppTests/Suite/test()`.
    public let test: String

    public static func inAppPurchases(test: String) -> ReviewScreenshot {
        ReviewScreenshot(kind: .inAppPurchases, test: test)
    }

    /// The test's run: its `ReviewScene` is named after the kind.
    public var capture: TestCapture {
        TestCapture(test: test, scene: Shot(kind.rawValue))
    }
}

/// In-app products.
public struct Products: Sendable {
    public var source: ProductSource
    /// The territory whose price the catalogue gives. Every other territory
    /// gets Apple's equalised price point.
    public var baseTerritory: String
    /// App Store Server Notifications, version 2, production and sandbox.
    /// Each subscription's App Review screenshot is the project's in-app
    /// purchases review screenshot.
    public var serverNotifications: URL?
    public var storeKit: StoreKitFile?

    public init(
        source: ProductSource,
        baseTerritory: String = "USA",
        serverNotifications: URL? = nil,
        storeKit: StoreKitFile? = nil
    ) {
        self.source = source
        self.baseTerritory = baseTerritory
        self.serverNotifications = serverNotifications
        self.storeKit = storeKit
    }
}

public enum ProductSource: Sendable {
    /// A shell command, run at the repository root, that prints the
    /// catalogue as JSON (see `ProductCatalogue`), for an app whose server
    /// defines what it sells.
    case command(String)
    /// The catalogue itself, for an app whose products nothing else defines.
    case catalogue(ProductCatalogue)
}

/// The local StoreKit configuration file Debug runs and tests buy from.
public struct StoreKitFile: Sendable {
    public var path: String
    public var teamID: String

    public init(path: String, teamID: String) {
        self.path = path
        self.teamID = teamID
    }
}
