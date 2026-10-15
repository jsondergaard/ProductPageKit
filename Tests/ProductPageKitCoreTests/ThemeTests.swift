import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ProductPageKitCore
import ProductPageKitFrames

/// A theme that draws nothing, for tests of what a project declares.
struct PlainFrames: FrameTheme {
    func render(_ shot: FramedShot, on canvas: Canvas) throws {}
}

struct PlainMotion: MotionTheme {
    var motion = Motion(seconds: 12, fps: 30, dissolve: 0.8)
    var assets: [CreativeAsset]

    func stage(for asset: CreativeAsset) -> any MotionStage { PlainStage() }
}

struct PlainStage: MotionStage {
    var deviceGlow: CGColor? { nil }
    func device(_ platform: Platform.Kind, screen: CGRect) -> any DeviceLook { DeviceBezel(platform.bezel, screen: screen) }
    func drawCaption(_ caption: Caption, on canvas: Canvas, locale: StoreLocale) -> CGRect { .zero }
    func background(at time: Double, layout: VideoLayout) -> CIImage { .empty() }
    func foreground(over image: CIImage, caption: CaptionLayer, layout: VideoLayout, at time: Double) -> CIImage { image }
}

@Suite struct CaptionTests {
    let en = StoreLocale("en", store: "en-US")
    let da = StoreLocale("da", store: "da")

    func copy(frames: Bool = true, videos: Bool = false) -> StoreCopy {
        var project = project(locales: [en, da])
        project.platforms = [.iPhone(shots: ["inbox", "detail"]), .mac(window: CGSize(width: 1280, height: 800), shots: ["inbox"])]
        if frames { project.frames = PlainFrames() }
        if videos {
            project.videos = PlainMotion(assets: [CreativeAsset(.header, poster: 0, devices: [
                DeviceLayer(.iPhone, screens: ["inbox"], x: 0.1, top: 0.1, width: 0.1, firstChange: 1, drift: .zero),
            ])])
        }
        var copy = StoreCopy(project: project, catalog: StringCatalog(sourceLanguage: "en"))
        for (field, value) in [(Field.name, "Example"), (.subtitle, "Alerts"), (.keywords, "push"), (.promotionalText, "New."),
                               (.description, "https://example.com/terms"), (.reviewNotes, "Sign in.")] {
            copy.set(value, field: field, locale: en)
        }
        return copy
    }

    @Test func eachShotHasACaptionOnceAThemeFramesIt() {
        let keys = copy().fields.map(\.key).filter { $0.hasPrefix("screenshot.") }
        #expect(keys == ["screenshot.inbox.kicker", "screenshot.inbox.headline", "screenshot.inbox.subline",
                         "screenshot.detail.kicker", "screenshot.detail.headline", "screenshot.detail.subline"])
        #expect(!copy(frames: false).fields.contains { $0.key.hasPrefix("screenshot.") })
        #expect(copy(frames: false, videos: true).fields.map(\.key).filter { $0.hasPrefix("video.") }
                == ["video.header.kicker", "video.header.headline", "video.header.subline"])
    }

    @Test func onlyTheHeadlineIsRequired() {
        var copy = copy()
        func captionProblems() -> [Problem] { copy.problems().filter { $0.message.hasPrefix("screenshot.") } }
        #expect(captionProblems().map(\.message).sorted() == ["screenshot.detail.headline is missing", "screenshot.inbox.headline is missing"])
        copy.set("Every alert.", field: .caption(.screenshot("inbox"), .headline), locale: en)
        copy.set("All of them.", field: .caption(.screenshot("detail"), .headline), locale: en)
        #expect(copy.problems().errors.isEmpty)
        #expect(captionProblems() == [.warning("screenshot.inbox.headline: not translated in da"),
                                      .warning("screenshot.detail.headline: not translated in da")])
    }

    @Test func captionsHaveNoCap() {
        let field = Field.caption(.screenshot("inbox"), .subline)
        #expect(field.maxLength == nil)
        #expect(field.comment == "Subline on the inbox screenshot.")
        var copy = copy()
        copy.set(String(repeating: "a", count: 5000), field: field, locale: en)
        #expect(!copy.problems().contains { $0.message.contains("characters") })
    }

    @Test func anUntranslatedLineShowsTheSourceAndSaysSo() throws {
        var copy = copy()
        let subject = CaptionSubject.screenshot(Shot("library", variant: "pro"))
        #expect(copy.caption(subject, locale: en) == nil)
        copy.set("Library", field: .caption(subject, .kicker), locale: en)
        copy.set("Everything you own.", field: .caption(subject, .headline), locale: en)
        copy.set("Alt du ejer.", field: .caption(subject, .headline), locale: da)
        let english = try #require(copy.caption(subject, locale: en))
        #expect(english.caption == Caption(kicker: "Library", headline: "Everything you own."))
        #expect(english.untranslated.isEmpty)
        let danish = try #require(copy.caption(subject, locale: da))
        #expect(danish.caption == Caption(kicker: "Library", headline: "Alt du ejer."))
        #expect(danish.untranslated.map(\.key) == ["screenshot.library-pro.kicker"])
        copy.catalog.set("Alt du ejer, igen.", for: "screenshot.library-pro.headline", language: "da", state: .needsReview)
        #expect(copy.caption(subject, locale: da)?.caption.headline == "Everything you own.")
    }

    @Test func captionKeysAreCopy() {
        #expect(copy().field("screenshot.inbox.kicker") == .caption(.screenshot("inbox"), .kicker))
        #expect(copy().field("screenshot.settings.kicker") == nil)
    }
}

@Suite struct MotionThemeTests {
    let iPhone = Platform.iPhone(shots: ["inbox", "quiet"])

    func problems(_ assets: [CreativeAsset], motion: Motion = Motion(seconds: 12, fps: 30, dissolve: 0.8)) -> [String] {
        PlainMotion(motion: motion, assets: assets).problems(platforms: [iPhone], files: ["film.mp4"])
    }

    func layer(_ platform: Platform.Kind = .iPhone, screens: [VideoScreen] = ["inbox", "quiet"], firstChange: Double = 2) -> DeviceLayer {
        DeviceLayer(platform, screens: screens, x: 0.1, top: 0.1, width: 0.1, firstChange: firstChange, drift: .zero)
    }

    @Test func aSoundDeclarationHasNoProblems() {
        #expect(problems([CreativeAsset(.header, poster: 0, devices: [layer()])]).isEmpty)
    }

    @Test func eachMistakeIsNamed() {
        #expect(problems([CreativeAsset(.header, poster: 0, devices: [layer()])], motion: Motion(seconds: 12, fps: 24, dissolve: 0.8))
                == ["videos run at 24 fps, and App Store Connect takes 30 or 60"])
        #expect(problems([CreativeAsset(.header, poster: 12, devices: [layer()])])
                == ["the product page header video's poster at 12.0 s is outside its 12.0 s loop"])
        #expect(problems([CreativeAsset(.search, poster: 0, devices: [layer(screens: [.movie("film.mp4", from: 0)])])])
                == ["the search results video, device 1 shows no capture to size its screen by",
                    "the search results video, device 1 plays film.mp4 across the loop's seam, where the movie would jump"])
        #expect(problems([CreativeAsset(.search, poster: 0, devices: [layer(screens: ["inbox", .movie("trailer.mp4", from: 4)])])])
                == ["the search results video, device 1 plays trailer.mp4, which the project's capture files do not include"])
        #expect(problems([CreativeAsset(.search, poster: 0, devices: [layer(.mac)])])
                == ["the search results video, device 1 is a Mac, which is not a configured platform"])
        #expect(problems([CreativeAsset(.header, poster: 0, devices: []), CreativeAsset(.header, poster: 0, devices: [layer()])])
                .sorted() == ["the product page header video has no devices", "the product page header video is declared twice"])
    }

    /// A movie plays from when its screen comes into view until it has
    /// dissolved away, which must happen inside the loop.
    @Test func aMoviePlaysWithinTheLoop() {
        let screens: [VideoScreen] = ["inbox", "quiet", .movie("film.mp4", from: 151)]
        #expect(problems([CreativeAsset(.header, poster: 0, devices: [layer(screens: screens)])]).isEmpty)
        let schedule = layer(screens: screens).schedule(Motion(seconds: 12, fps: 30, dissolve: 0.8))
        #expect(schedule.window(of: 2) == 5.2...10)
        #expect(schedule.window(of: 0).lowerBound < 0)
    }

    @Test func devicesFloatStaggeredOrInStep() {
        let staggered = Motion(seconds: 12, fps: 30, dissolve: 0.8)
        let quarters: [Double] = [0, 0.5, 1, 1.5].map { $0 * Double.pi }
        #expect((0..<4).map { staggered.floatPhase($0, of: 4) } == quarters)
        let inStep = Motion(seconds: 12, fps: 30, dissolve: 0.8, floating: .inStep)
        #expect((0..<4).map { inStep.floatPhase($0, of: 4) } == [Double](repeating: 0, count: 4))
    }

    /// The poster is the still App Store Connect shows before the loop plays.
    @Test func thePosterMayNotCatchADissolve() {
        #expect(problems([CreativeAsset(.header, poster: 1.8, devices: [layer(firstChange: 2)])])
                == ["the product page header video's poster frame catches device 1 mid-dissolve"])
    }
}

@Suite struct CacheIndexTests {
    @Test func writingDeletesWhatItNoLongerNames() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CacheIndexTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["a.png", "b.png", "c.png", "d.png"] { try Data().write(to: directory.appending(path: name)) }
        let en = StoreLocale("en", store: "en-US"), da = StoreLocale("da", store: "da")
        let inbox = FramedItem(FrameSubject("inbox", on: .iPhone), locale: en)
        let detail = FramedItem(FrameSubject("detail", on: .iPhone), locale: en)
        let danish = FramedItem(FrameSubject("inbox", on: .iPhone), locale: da)
        try CacheIndex.update(in: directory, with: [(inbox, "a.png"), (detail, "b.png"), (danish, "c.png")]) { _ in false }
        // A later run of the English set replaces one file and drops the shot it no longer lists.
        try CacheIndex.update(in: directory, with: [(inbox, "d.png")]) { $0.locale == "en" }
        try Data().write(to: directory.appending(path: "stray.png"))
        try CacheIndex<FramedItem>.prune(in: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["c.png", "index.json"])
        let read = CacheIndex<FramedItem>.read(in: directory)
        #expect(read.file(for: inbox) == "d.png")
        #expect(read.file(for: danish) == "c.png")
        #expect(read.file(for: detail) == nil)
    }
}

@Suite struct DisplaySizeTests {
    @Test func themesFrameAtTheLargestSizeEachDisplayTakes() {
        #expect(Platform.Kind.iPhone.screenshotSize == CGSize(width: 1320, height: 2868))
        #expect(Platform.Kind.iPad.screenshotSize == CGSize(width: 2064, height: 2752))
        #expect(Platform.Kind.mac.screenshotSize == CGSize(width: 2880, height: 1800))
        #expect(Platform.Kind.appleTV.screenshotSize == CGSize(width: 3840, height: 2160))
        #expect(Platform.Kind.iPhone.acceptedSizes.contains(CGSize(width: 2868, height: 1320)))
        #expect(!Platform.Kind.mac.acceptedSizes.contains(CGSize(width: 1600, height: 1200)))
    }

    @Test func videoCanvasesAndSafeAreasAreApples() {
        #expect(CreativeAsset.Kind.header.size == CGSize(width: 3840, height: 1646))
        #expect(CreativeAsset.Kind.search.size == CGSize(width: 3840, height: 2560))
        for kind in CreativeAsset.Kind.allCases {
            #expect(CGRect(origin: .zero, size: kind.size).contains(kind.safeArea))
        }
    }
}
