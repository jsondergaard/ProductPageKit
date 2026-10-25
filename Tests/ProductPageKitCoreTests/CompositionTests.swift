import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKitCore
import ProductPageKitFrames

/// A theme that composes its frames, as a brand drawing the app's parts
/// rather than one capture would.
struct ComposedFrames: FrameTheme {
    func sources(for frame: FrameSubject) -> [FrameSource] {
        switch (frame.shot.name, frame.list) {
        case ("devices", _):
            [.capture("home", on: .iPhone), .capture("home", on: .mac)]
        case ("free", _):
            [.component("value-list", on: frame.platform), .component("value-list", on: frame.platform).inPrimaryLocale(),
             .file("film.mp4")]
        case ("server", .customPage(let page)):
            [.capture(Shot("library", variant: page), on: frame.platform), .component(Component("sources", variant: page), on: frame.platform)]
        default:
            [.capture(frame.shot, on: frame.platform)]
        }
    }

    func render(_ shot: FramedShot, on canvas: Canvas) throws {}
}

struct FilmFiles: CaptureFiles {
    var port: UInt16 { 8721 }
    var names: [String] { ["film.mp4"] }
    func prepare(in directory: URL, log: @escaping @Sendable (String) -> Void) async throws {}
}

@Suite struct CompositionTests {
    func composed() -> Project {
        var example = project()
        example.platforms = [.iPhone(shots: ["devices", "library", "free"]), .mac(window: CGSize(width: 1440, height: 900), shots: ["library"])]
        example.frames = ComposedFrames()
        example.files = FilmFiles()
        example.customPages = [CustomPage("pro", name: "Pro", platforms: [.iPhone], shots: ["server", "free"], storeCaptions: ["free"])]
        return example
    }

    @Test func whatIsCapturedIsWhatTheFramesDraw() {
        let example = composed()
        #expect(example.captures(on: .iPhone) == ["home", "library", Shot("library", variant: "pro")])
        #expect(example.captures(on: .mac) == ["home", "library"])
        #expect(example.components(on: .iPhone) == ["value-list", Component("sources", variant: "pro")])
        #expect(example.components(on: .mac).isEmpty)
        #expect(example.problems().isEmpty)
    }

    @Test func withoutAThemeEachShotIsItsOwnCapture() {
        var example = composed()
        example.frames = nil
        #expect(example.captures(on: .iPhone) == ["devices", "library", "free", "server"])
        #expect(example.components(on: .iPhone).isEmpty)
    }

    @Test func videosAddTheScreensTheyShow() {
        var example = composed()
        example.videos = PlainMotion(assets: [CreativeAsset(.header, poster: 0, devices: [
            DeviceLayer(.mac, screens: ["guide", .movie("film.mp4", from: 1)], x: 0, top: 0, width: 0.1, firstChange: 1, drift: .zero),
        ])])
        #expect(example.captures(on: .mac) == ["home", "library", "guide"])
    }

    /// A render takes what the frames do not already take, on a configured
    /// platform; a test's screens are listed once each.
    @Test func rendersAddOnlyWhatTheFramesDoNotTake() {
        var example = composed()
        example.renders = [Render("home", .capture("home", on: .iPhone)), Render("player", .capture("player", on: .iPhone)),
                           Render("values", .component("value-list", on: .iPhone)),
                           Render("badges", .component(Component("badges", state: "hdr"), on: .mac)),
                           Render("menu-audio", .test("AppUITests/Renders/testMenus", scene: Shot("menu", variant: "audio"), on: .iPhone)),
                           Render("menu-audio-again", .test("AppUITests/Renders/testMenus", scene: Shot("menu", variant: "audio"), on: .iPhone)),
                           Render("menu-off", .test("AppUITests/Renders/testMenus", scene: Shot("menu", variant: "off"), on: .iPhone))]
        #expect(example.renderCaptures(on: .iPhone) == ["player"])
        #expect(example.renderComponents(on: .iPhone).isEmpty)
        #expect(example.renderComponents(on: .mac) == [Component("badges", state: "hdr")])
        #expect(example.renderTests(on: .iPhone).map(\.scene) == [Shot("menu", variant: "audio"), Shot("menu", variant: "off")])
        #expect(example.renderTests(on: .mac).isEmpty)
        #expect(example.problems().isEmpty)

        example.renders += [Render("player", .capture("player", on: .mac)), Render("player", .capture("guide", on: .mac)),
                            Render("tv", .capture("player", on: .appleTV)), Render("a/b", .capture("home", on: .mac))]
        #expect(example.problems() == [
            "the Mac render player is listed twice",
            "the render \"a/b\" needs a name that is a file name",
            "the render tv is on the Apple TV, which is not a configured platform",
        ])
    }

    /// A test's screen is filed as its scene, beside the app's captures.
    @Test func aTestRenderIsFiledAsItsScene() throws {
        let cache = Cache(bundleID: "com.example.app", root: URL(filePath: "/tmp/cache"))
        let platform = try #require(composed().platform(.iPhone))
        let render = Render("menu", .test("AppUITests/Renders/testMenus", scene: Shot("menu", variant: "off"), on: .iPhone))
        #expect(cache.file(render, on: platform, in: StoreLocale("en", store: "en-US")).path
                == "/tmp/cache/com.example.app/raw/ios/en/menu-off.png")
    }

    @Test func aReviewScreenshotIsItsTestsScene() {
        #expect(ReviewScreenshot.inAppPurchases(test: "AppTests/Review/capture()").capture
                == TestCapture(test: "AppTests/Review/capture()", scene: "inAppPurchases"))
    }

    @Test func framesListEveryPageAfterThePlatforms() {
        #expect(composed().frameSubjects.map { "\($0.platform.rawValue) \($0.shot) \($0.list.folder ?? "-")" }
                == ["ios devices -", "ios library -", "ios free -", "macos library -", "ios server page-pro", "ios free page-pro"])
    }

    @Test func aSourceOnAnUnconfiguredPlatformOrAMissingFileIsAProblem() {
        var example = composed()
        example.files = nil
        example.platforms = [.iPhone(shots: ["devices", "free"])]
        #expect(example.problems() == [
            "the iPhone 6.9\" devices screenshot draws the Mac capture of home, and the Mac is not a configured platform",
            "the iPhone 6.9\" free screenshot draws the file film.mp4, which the project's capture files do not include",
            "the iPhone 6.9\" free screenshot draws the file film.mp4, which the project's capture files do not include",
        ])
    }

    /// A brand may draw at any size the display type takes, and no other.
    @Test func aThemeDrawsAtASizeAppStoreConnectTakes() {
        struct Sized: FrameTheme {
            let size: CGSize
            func canvasSize(for platform: Platform.Kind) -> CGSize { platform == .iPhone ? size : platform.screenshotSize }
            func render(_ shot: FramedShot, on canvas: Canvas) throws {}
        }
        var example = composed()
        example.frames = Sized(size: CGSize(width: 1290, height: 2796))
        #expect(example.problems().isEmpty)
        example.frames = Sized(size: CGSize(width: 1300, height: 2800))
        #expect(example.problems() == ["the theme draws iPhone 6.9\" screenshots at 1300 × 2800, which App Store Connect does not take"])
    }

    @Test func aSourceInThePrimaryLocaleIsADifferentSource() {
        let source = FrameSource.component("value-list", on: .iPhone)
        #expect(source.inPrimaryLocale() != source)
        #expect(source.inPrimaryLocale().isInPrimaryLocale)
        #expect(FrameSource.file("film.mp4").inPrimaryLocale() == .file("film.mp4"))
        #expect("\(source.inPrimaryLocale())" == "the iPhone 6.9\" component value-list, in the primary locale")
    }

    @Test func aThemeCanReadOnlyWhatItListed() throws {
        let image = Canvas(size: CGSize(width: 4, height: 4)).image()
        let shot = FramedShot(shot: "free", position: 2, count: 3, platform: .iPhone, locale: StoreLocale("en", store: "en-US"),
                              caption: Caption(headline: "Free."), images: [.component("value-list", on: .iPhone): image],
                              files: ["film.mp4": URL(filePath: "/tmp/film.mp4")])
        #expect(try shot.image(.component("value-list", on: .iPhone)).width == 4)
        #expect(try shot.highlights(.component("value-list", on: .iPhone)).isEmpty)
        #expect(try shot.file("film.mp4").lastPathComponent == "film.mp4")
        let error = #expect(throws: UndeclaredSource.self) { try shot.capture }
        #expect(error?.description == "the theme drew the iPhone 6.9\" capture of free into the iPhone 6.9\" free screenshot without listing it in sources(for:)")
    }

    @Test func componentsAreFiledByStateAndVariant() {
        #expect(Component("sources").fileName == "sources")
        #expect(Component("detail-sources", state: "1").fileName == "detail-sources@1")
        #expect(Component("sources", variant: "pro").fileName == "sources-pro")
        #expect(Component("detail-sources", state: "1", variant: "pro").description == "detail-sources (state 1, pro)")
    }
}

@Suite struct CustomPageTests {
    let en = StoreLocale("en", store: "en-US")

    @Test func aPageCaptionsItsShotsUnlessItTakesTheStores() {
        let page = CustomPage("pro", name: "Pro", shots: ["server", "free"], storeCaptions: ["free"])
        #expect(page.captionSubject("server") == .pageScreenshot("pro", "server"))
        #expect(page.captionSubject("free") == .screenshot("free"))
        #expect(Field.caption(.pageScreenshot("pro", "server"), .headline).key == "page.pro.screenshot.server.headline")
        #expect(page.promotionalText.key == "page.pro.promotionalText")
        #expect(page.promotionalText.maxLength == 170)
        #expect(page.fileName(for: "free") == "02_free")
    }

    @Test func pageCopyIsInTheCatalog() {
        var example = project()
        example.platforms = [.iPhone(shots: ["free"])]
        example.frames = PlainFrames()
        example.customPages = [CustomPage("pro", name: "Pro", platforms: [.iPhone], shots: ["server", "free"], storeCaptions: ["free"])]
        let copy = StoreCopy(project: example, catalog: StringCatalog(sourceLanguage: "en"))
        let keys = copy.fields.map(\.key)
        #expect(keys.contains("page.pro.promotionalText"))
        #expect(keys.contains("page.pro.screenshot.server.headline"))
        #expect(!keys.contains("page.pro.screenshot.free.headline"))
        #expect(copy.problems().map(\.message).contains("page.pro.promotionalText is missing"))
    }

    /// App Store Connect refuses a custom page's Mac and Apple TV
    /// screenshots.
    @Test func aPageIsForIPhoneAndIPadOnly() {
        var example = project()
        example.platforms = [.iPhone(shots: ["home"]), .mac(window: CGSize(width: 1280, height: 800), shots: ["home"]), .appleTV(shots: ["home"])]
        example.customPages = [
            CustomPage("tv", name: "TV", platforms: [.appleTV, .mac, .iPad], shots: ["home", "home"], storeCaptions: ["guide"], keywords: ["a,b"]),
            CustomPage("tv", name: "Television", platforms: [.iPhone], shots: ["home"]),
            CustomPage("box", name: "TV", platforms: [.iPhone], shots: []),
        ]
        #expect(example.problems() == [
            "the box page has no shots",
            "the tv page gives guide the store's caption, and does not list it",
            "the tv page has the keyword \"a,b\", and a keyword is one term without commas",
            "the tv page is listed twice",
            "the tv page lists home twice",
            "the tv page lists the Apple TV, and App Store Connect takes only iPhone and iPad screenshots for a custom page",
            "the tv page lists the Mac, and App Store Connect takes only iPhone and iPad screenshots for a custom page",
            "the tv page lists the iPad 13\", which is not a configured platform",
            "two custom pages are named TV",
        ])
    }
}

@Suite struct StoreLocaleTests {
    /// A storefront the app has no localization of shows the nearest one.
    @Test func aStoreOnlyLocaleRunsTheAppInAnother() {
        let mexico = StoreLocale("es-MX", store: "es-MX", app: "es-419")
        #expect(mexico.app == "es-419")
        #expect(mexico.localeIdentifier == "es_MX")
        #expect(StoreLocale("da", store: "da").app == "da")
    }

    @Test func arabicIsRightToLeft() {
        #expect(StoreLocale("ar", store: "ar-SA").isRightToLeft)
        #expect(!StoreLocale("en", store: "en-US").isRightToLeft)
    }
}
