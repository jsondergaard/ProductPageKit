import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ProductPageKit
@testable import ProductPageKitRunner

/// `screenshots capture` on `Fixtures/SampleApp`, on iPhone and Apple TV
/// simulators and on this Mac. Serialized: the tests build into the sample's
/// DerivedData, and the Mac capture takes the front window.
@Suite(.serialized)
struct CaptureTests {
    static let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let en = StoreLocale("en", store: "en-US")
    static let da = StoreLocale("da", store: "da")

    static let project = Project(
        name: "Sample",
        bundleID: "com.productpagekit.sample",
        xcode: .project("Fixtures/SampleApp/SampleApp.xcodeproj", scheme: "SampleApp"),
        locales: [en, da],
        appearance: .dark,
        platforms: [
            .iPhone(shots: ["list", Shot("detail", variant: "blue"), "settings"]),
            .appleTV(shots: ["list", Shot("detail", variant: "blue"), "settings"]),
            .mac(window: CGSize(width: 800, height: 600), shots: ["list", Shot("detail", variant: "blue"), "settings"]),
        ],
        reviewScreenshots: [.inAppPurchases(test: "SampleAppTests/ReviewScreenshotTests/inAppPurchases()")],
        frames: SampleFrames(),
        // Taken in English alone: a scene no frame draws, a component in a
        // variant none does, and a screen a test puts up in two variants.
        renders: [Render("detail-site", .capture("detail", on: .iPhone)), Render("basket-site", .component("basket", on: .appleTV))]
            + [Platform.Kind.iPhone, .mac].flatMap { platform in
                ["red", "blue"].map { (colour: String) in
                    Render("banner-\(colour)", .test(CaptureTests.banner, scene: Shot("banner", variant: colour), on: platform))
                }
            },
        metadata: Metadata(urls: URLs(marketing: "https://example.com", support: "https://example.com/support",
                                      privacy: "https://example.com/privacy"),
                           copyright: "2026 Example")
    )

    static let banner = "SampleAppTests/RenderTests/banner()"

    var session: (Session, RecordingConsole) {
        let console = RecordingConsole()
        let session = Session(project: Self.project, root: Self.packageRoot, environment: Environment(values: [:]),
                              console: console, cache: Cache(bundleID: Self.project.bundleID)) {
            throw Stopped(description: "no App Store Connect in capture tests")
        }
        return (session, console)
    }

    static let sizes: [Platform.Kind: CGSize] = [
        .iPhone: CGSize(width: 1320, height: 2868), .appleTV: CGSize(width: 3840, height: 2160),
        // The Mac window's 800 × 600 points at 2×.
        .mac: CGSize(width: 1600, height: 1200),
    ]

    /// On one worker, so the simulator moves from one locale to the other.
    @Test func capturesEveryShotInEveryLocaleOnEveryPlatform() async throws {
        let (session, console) = session
        let report = try #require(try await Commands.captureScreenshots(session, platforms: "", locales: "", shots: "",
                                                                          workers: 1, force: true, dryRun: false))
        let names = ["01_list.png", "02_detail-blue.png", "03_settings.png"]
        let banners = ["banner-blue.png", "banner-red.png"]
        #expect(report.shots.map(\.lastPathComponent).sorted()
                == ([[String]](repeating: names, count: 6).flatMap(\.self) + ["detail.png"] + banners + banners).sorted())
        #expect(report.components.map(\.lastPathComponent).sorted() == ([String](repeating: "basket-blue.png", count: 6) + ["basket.png"]).sorted())
        for platform in Self.project.platforms {
            var sizes: Set<CGSize> = []
            for locale in [Self.en, Self.da] {
                let directory = session.cache.raw(platform, locale)
                let render = switch (platform.kind, locale == Self.en) {
                case (.iPhone, true): ["detail.png"] + banners
                case (.mac, true): banners
                default: [String]()
                }
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                        == (names + render + ["03_settings.json"]).sorted())
                for name in names {
                    let image = try Self.image(directory.appending(path: name))
                    sizes.insert(Self.size(image))
                    #expect(Self.size(image) == Self.sizes[platform.kind], "\(platform.id)/\(locale.code)/\(name)")
                    #expect(!Self.isBlank(image), "\(platform.id)/\(locale.code)/\(name) is one colour")
                }
                // The Notifications toggle, in the capture's pixels: one row
                // high, below the title bar or the status bar.
                let settings = directory.appending(path: "03_settings.png")
                let highlights = try JSONDecoder().decode(Highlights.self, from: Data(contentsOf: Highlights.url(for: settings))).rects
                let image = try Self.image(settings)
                let row = try #require(highlights.first)
                #expect(highlights.count == 1)
                #expect(CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(row), "\(platform.id) \(row)")
                #expect(row.minY > CGFloat(image.height) * 0.05 && row.height < CGFloat(image.height) * 0.05, "\(platform.id) \(row)")
                #expect(!Self.isBlank(try #require(image.cropping(to: row))), "\(platform.id) \(row) is one colour")
                // The scene's title is drawn in the locale, so the two
                // languages' captures differ.
                let english = try Data(contentsOf: session.cache.raw(platform, Self.en).appending(path: "01_list.png"))
                let danish = try Data(contentsOf: session.cache.raw(platform, Self.da).appending(path: "01_list.png"))
                #expect(english != danish)
                // Its screenshots keep the display's mask.
                if platform.kind == .iPhone {
                    for name in names {
                        let corner = try #require(Self.image(directory.appending(path: name)).cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
                        #expect(FramerTests.contains(.hex(0x000000), in: corner), "\(locale.code)/\(name) has no display mask")
                    }
                }
            }
            #expect(sizes.count == 1, "\(platform.id) shots differ in size: \(sizes)")
            // The basket's rounded corners are clear, its middle blue, and
            // nothing around it.
            for locale in [Self.en, Self.da] {
                let basket = try Self.image(session.cache.component(platform, locale, SampleFrames.basket))
                let pixels = try #require(FrameStability.pixels(basket))
                #expect(pixels[3] == 0, "\(platform.id)/\(locale.code) basket corner")
                let middle = (basket.height / 2 * basket.width + basket.width / 2) * 4
                #expect(pixels[middle + 3] == 255 && pixels[middle + 2] > pixels[middle], "\(platform.id)/\(locale.code) basket middle")
                // Laid out 300 points wide, at the platform's scale or more.
                #expect(basket.width >= 300, "\(platform.id) basket is \(basket.width) wide")
            }
            let review = try Self.image(session.cache.review(platform, .inAppPurchases))
            #expect(!Self.isBlank(review))
            #expect(review.width > 400, "\(platform.id) review screenshot is \(review.width) wide")
        }
        #expect(report.reviewScreenshots.count == 3)
        #expect(console.output.contains("Captured 23 screenshots, 7 components and 3 App Review screenshots"))
        // The test's two variants, each its own colour, the spinner left out
        // of the check for still frames.
        for platform in [Self.project.platforms[0], Self.project.platforms[2]] {
            let red = try Self.image(session.cache.capture(platform, Self.en, Shot("banner", variant: "red")))
            let blue = try Self.image(session.cache.capture(platform, Self.en, Shot("banner", variant: "blue")))
            let middle = CGRect(x: red.width / 4, y: red.height / 5, width: red.width / 2, height: red.height / 10)
            let (redR, _, redB) = try Self.meanColour(try #require(red.cropping(to: middle)))
            let (blueR, _, blueB) = try Self.meanColour(try #require(blue.cropping(to: middle)))
            #expect(redR > redB + 60, "\(platform.id) red banner")
            #expect(blueB > blueR + 60, "\(platform.id) blue banner")
        }
        #expect(FileManager.default.fileExists(atPath: session.cache.component(Self.project.platforms[1], Self.en, "basket").path))
        #expect(!FileManager.default.fileExists(atPath: session.cache.component(Self.project.platforms[1], Self.da, "basket").path))
        try await Self.frameAndRender()
    }

    /// The captures framed with the sample theme and put into a video.
    static func frameAndRender() async throws {
        var project = Self.project
        project.videos = SampleMotion(shots: ["list", .capture(Shot("detail", variant: "blue"))])
        let root = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var copy = StoreCopy(project: project, catalog: StringCatalog(sourceLanguage: "en"))
        for subject in project.captionSubjects {
            copy.set("A headline for \(subject)", field: .caption(subject, .headline), locale: en)
            copy.set("En overskrift til \(subject)", field: .caption(subject, .headline), locale: da)
        }
        try copy.write(root: root)
        let session = Session(project: project, root: root, environment: Environment(values: [:]), console: RecordingConsole(),
                              cache: Cache(bundleID: project.bundleID)) {
            throw Stopped(description: "no App Store Connect in capture tests")
        }
        let framed = try await Commands.frameScreenshots(session, platforms: project.platforms, locales: project.locales)
        #expect(framed.screenshots.count == 18)
        for screenshot in framed.screenshots {
            let image = try image(screenshot.url)
            #expect(size(image) == screenshot.platform.kind.screenshotSize)
            #expect(!isBlank(image))
        }
        let videos = try await Commands.renderVideos(session, locales: project.locales)
        #expect(videos.videos.count == 2)
        #expect(videos.videos.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test func aSubsetCapturesAnExtraSceneUnnumberedAndKeepsTheRest() async throws {
        let (session, _) = session
        let report = try #require(try await Commands.captureScreenshots(session, platforms: "ios", locales: "en", shots: "detail",
                                                                          workers: nil, force: true, dryRun: false))
        #expect(report.shots.map(\.lastPathComponent) == ["detail.png"])
        #expect(report.reviewScreenshots.isEmpty)
        let directory = session.cache.raw(Self.project.platforms[0], Self.en)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.contains("detail.png"))
    }

    /// A second run from the same app, device and settings takes nothing, and
    /// launches nothing; a capture that is gone, or whose inputs changed, is
    /// taken again, and `--force` takes everything.
    @Test func aRepeatedRunKeepsWhatItTook() async throws {
        let (session, console) = session
        func run(force: Bool) async throws -> CaptureReport {
            try #require(try await Commands.captureScreenshots(session, platforms: "ios", locales: "en", shots: "detail",
                                                                workers: nil, force: force, dryRun: false))
        }
        #expect(try await run(force: true).shots.count == 1)
        let again = try await run(force: false)
        #expect(again.shots.isEmpty)
        #expect(again.unchanged == 1)
        #expect(console.output.contains("Everything is up to date: 1 capture kept"))
        let file = session.cache.capture(Self.project.platforms[0], Self.en, Shot("detail"))
        try FileManager.default.removeItem(at: file)
        #expect(try await run(force: false).shots.map(\.lastPathComponent) == ["detail.png"])
        // A different stamp: the ledger's record of the capture is stale.
        let ledger = session.cache.directory.appending(path: "ledger/\(Self.project.platforms[0].id)/en.json")
        try Data("{}".utf8).write(to: ledger)
        #expect(try await run(force: false).shots.count == 1)
        #expect(try await run(force: true).shots.count == 1)
    }

    /// An iPhone Duo simulator boots folded; the capture opens it flat and
    /// photographs its inner display, which is landscape.
    @Test func iPhoneDuoIsCapturedOpenedFlat() async throws {
        var project = Self.project
        project.platforms = [.iPhoneDuo(shots: ["list"])]
        project.reviewScreenshots = []
        project.renders = []
        let console = RecordingConsole()
        let session = Session(project: project, root: Self.packageRoot, environment: Environment(values: [:]),
                              console: console, cache: Cache(bundleID: project.bundleID)) {
            throw Stopped(description: "no App Store Connect in capture tests")
        }
        let report = try #require(try await Commands.captureScreenshots(session, platforms: "duo", locales: "en", shots: "",
                                                                          workers: 1, force: true, dryRun: false))
        let file = try #require(report.shots.first)
        let frame = try Frame(png: try Data(contentsOf: file))
        #expect(CGSize(width: frame.image.width, height: frame.image.height) == Platform.Kind.iPhoneDuo.screenshotSize)
        #expect(frame.showsContent)
    }

    /// Everything in ProductPageKitCapture is DEBUG only, so a Release build
    /// of an app that links it carries none of it.
    @Test func aReleaseBuildCarriesNoProductPageKitSymbols() async throws {
        let derived = Cache(bundleID: Self.project.bundleID).directory.appending(path: "release-check")
        _ = try await Shell.run("/usr/bin/xcrun", [
            "xcodebuild", "build", "-project", "Fixtures/SampleApp/SampleApp.xcodeproj", "-scheme", "SampleApp",
            "-configuration", "Release", "-destination", "platform=macOS", "-derivedDataPath", derived.path,
            "-skipPackagePluginValidation",
        ], in: Self.packageRoot, log: derived.appending(path: "build.log"))
        let binary = derived.appending(path: "Build/Products/Release/SampleApp.app/Contents/MacOS/SampleApp").path
        // Symbols, without the debugger's notes of which files went in.
        let symbols = String(decoding: try await Shell.run("/usr/bin/nm", [binary]), as: UTF8.self)
        let strings = String(decoding: try await Shell.run("/usr/bin/strings", [binary]), as: UTF8.self)
        #expect(!symbols.isEmpty)
        #expect(!symbols.contains("ProductPageKit"))
        #expect(!strings.contains("ProductPageKit"))
        #expect(!strings.contains("ProductPageControl"))
    }

    static func image(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func size(_ image: CGImage) -> CGSize { CGSize(width: image.width, height: image.height) }

    /// Every pixel the same colour, which is what a capture of nothing is.
    /// The average of each channel, from 0 to 255.
    static func meanColour(_ image: CGImage) throws -> (Int, Int, Int) {
        let pixels = try #require(FrameStability.pixels(image))
        var sums = [0, 0, 0]
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { sums[channel] += Int(pixels[pixel + channel]) }
        }
        let count = max(1, pixels.count / 4)
        return (sums[0] / count, sums[1] / count, sums[2] / count)
    }

    static func isBlank(_ image: CGImage) -> Bool {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: pixels.count, by: 4).allSatisfy { pixels[$0..<$0 + 4] == pixels[0..<4] }
    }
}

@Suite struct CaptureCommandTests {
    @Test func aDryRunPrintsThePlanAndBuildsNothing() async throws {
        let console = RecordingConsole()
        let session = Session(project: CaptureTests.project, root: CaptureTests.packageRoot, environment: Environment(values: [:]),
                              console: console, cache: Cache(bundleID: "com.productpagekit.dry-run",
                                                             root: FileManager.default.temporaryDirectory)) {
            throw Stopped(description: "no App Store Connect")
        }
        let report = try await Commands.captureScreenshots(session, platforms: "macos", locales: "da", shots: "detail:blue,settings",
                                                           workers: nil, force: false, dryRun: true)
        #expect(report == nil)
        #expect(console.output == """
            Mac: a 800 × 600 window, 1 worker
              da: 02_detail-blue.png 03_settings.png
            Dry run: nothing built or captured.
            """)
    }

    @Test func workersMustBePositive() async {
        let (session, _) = CaptureTests().session
        await #expect(throws: Stopped.self) {
            try await Commands.captureScreenshots(session, platforms: "", locales: "", shots: "", workers: 0, force: false, dryRun: true)
        }
    }

    @Test func shotsTakeAVariantAfterAColon() {
        #expect(Commands.shotList(" inbox, library:pro ,") == ["inbox", Shot("library", variant: "pro")])
        #expect(Commands.shotList("") == nil)
    }
}
