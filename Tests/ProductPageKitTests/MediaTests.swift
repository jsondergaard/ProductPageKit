import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKit
@testable import ProductPageKitASC
@testable import ProductPageKitCore
import ProductPageKitTestSupport

@Suite struct ScreenshotsTests {
    func iPhoneSet(_ fake: FakeAppStoreConnect, locale: String) throws -> [FakeAppStoreConnect.Resource] {
        let localization = try #require(fake.all("appStoreVersionLocalizations").first { $0.attributes["locale"] as? String == locale })
        let set = try #require(fake.all("appScreenshotSets").first {
            $0.relationships["appStoreVersionLocalization"]?.id == localization.id
                && $0.attributes["screenshotDisplayType"] as? String == "APP_IPHONE_67"
        })
        return fake.screenshots(inSet: set.id)
    }

    func push(_ fixture: Fixture, platforms: String = "ios", locales: String = "en") async throws {
        try await Commands.pushScreenshots(fixture.session, platforms: platforms, locales: locales, options: apply)
    }

    @Test func uploadsEachSetInListOrderThenFindsNothingToChange() async throws {
        let fixture = try Fixture()
        try fixture.writeCaptures()

        try await push(fixture, platforms: "", locales: "")

        let english = try iPhoneSet(fixture.fake, locale: "en-US")
        #expect(english.map { $0.attributes["fileName"] as? String } == ["01_home.png", "02_list.png"])
        // Danish did not exist, so it was created with its copy first.
        let danish = try #require(fixture.fake.all("appStoreVersionLocalizations").first { $0.attributes["locale"] as? String == "da" })
        #expect(danish.attributes["keywords"] as? String == "push,personsøger")
        #expect(try iPhoneSet(fixture.fake, locale: "da").count == 2)
        #expect(fixture.console.output.contains("warning: macOS has no editable version, so Mac screenshots are left as they are"))

        fixture.fake.clearWrites()
        let second = try fixture.again()
        try await push(second, locales: "")
        #expect(second.console.output.contains("4 screenshots already framed."))
        #expect(second.console.output.contains("Nothing to change."))
        #expect(fixture.fake.writes.isEmpty)
    }

    /// A localization's sets are read once for all its iOS platforms, and a
    /// set per platform is made, iPhone Duo's under its own display type.
    @Test func eachLocalizationIsReadOnceForAllItsPlatforms() async throws {
        let fixture = try Fixture()
        fixture.project.platforms = [.iPhone(shots: ["home", "list"]), .iPad(shots: ["home"]), .iPhoneDuo(shots: ["home"])]
        try fixture.writeCaptures()
        try await push(fixture, platforms: "", locales: "")
        #expect(Set(fixture.fake.all("appScreenshotSets").compactMap { $0.attributes["screenshotDisplayType"] as? String })
                == ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129", "APP_IPHONE_DUO"])

        fixture.fake.clearReads()
        try await Commands.pushScreenshots(fixture.session, platforms: "", locales: "", options: dryRun)
        // The first page of each localization's sets; the fake pages two at a time.
        let firstPages = fixture.fake.reads.filter { $0.contains("/appScreenshotSets?") && !$0.contains("cursor=") }
        #expect(firstPages.count == 2, "\(fixture.fake.reads)")
        #expect(fixture.console.output.hasSuffix("Nothing to change."))
    }

    @Test func onlyAChangedCaptureIsUploaded() async throws {
        let fixture = try Fixture()
        try fixture.writeCaptures()
        try await push(fixture)
        let before = try iPhoneSet(fixture.fake, locale: "en-US").map(\.id)

        fixture.fake.clearWrites()
        try fixture.writeCapture(.iPhone, fixture.en, "list", shade: 250)
        try await push(fixture)

        let after = try iPhoneSet(fixture.fake, locale: "en-US")
        #expect(after[0].id == before[0])
        #expect(after[1].id != before[1])
        #expect(fixture.fake.writes.filter { $0 == "POST /v1/appScreenshots" }.count == 1)
        #expect(fixture.fake.writes.filter { $0.hasPrefix("DELETE") }.count == 1)
    }

    @Test func swappedCapturesOnlyReorder() async throws {
        let fixture = try Fixture()
        try fixture.writeCapture(.iPhone, fixture.en, "home", shade: 10)
        try fixture.writeCapture(.iPhone, fixture.en, "list", shade: 200)
        try await push(fixture)

        fixture.fake.clearWrites()
        try fixture.writeCapture(.iPhone, fixture.en, "home", shade: 200)
        try fixture.writeCapture(.iPhone, fixture.en, "list", shade: 10)
        try await push(fixture)
        #expect(fixture.fake.writes.count == 1)
        #expect(fixture.fake.writes[0].hasSuffix("/relationships/appScreenshots"))
    }

    @Test func aMissingCaptureStopsBeforeAnyRequest() async throws {
        let fixture = try Fixture()
        try fixture.writeCapture(.iPhone, fixture.en, "home")
        let error = await #expect(throws: Stopped.self) { try await push(fixture) }
        #expect(error?.description.contains("no iPhone 6.9\" capture of list in en") == true)
        #expect(fixture.fake.writes.isEmpty)
    }

    /// An iPhone screenshot named `name`, whose bytes are its name.
    func localScreenshot(_ name: String, in fixture: Fixture) throws -> LocalScreenshot {
        let url = fixture.root.appending(path: name)
        try Data(name.utf8).write(to: url)
        return try LocalScreenshot(FramedScreenshot(subject: FrameSubject("home", on: .iPhone), platform: .iPhone(), locale: fixture.en,
                                                    url: url, name: name))
    }

    @Test func matchingIsByChecksumOnePerFile() throws {
        let file = try localScreenshot("01_home.png", in: try Fixture())
        let complete = Screenshot(id: "a", checksum: file.checksum, state: "COMPLETE")
        let twice = SetSync(local: [file, file], remote: [complete])
        #expect(twice.kept.count == 1)
        #expect(twice.upload.count == 1)
        let failed = SetSync(local: [file], remote: [Screenshot(id: "a", checksum: file.checksum, state: "FAILED")])
        #expect(failed.delete.map(\.id) == ["a"])
        #expect(failed.upload.count == 1)
        #expect(SetSync(local: [file], remote: [complete]).isEmpty)
    }

    /// A set App Store Connect fills after the plan is made is synced from
    /// what it holds when the change runs.
    @Test func aFilledSetIsSyncedFromWhatItHoldsWhenTheChangeRuns() async throws {
        let fixture = try Fixture()
        var plan = Plan()
        plan.syncSets("Story set · en-US", [LocalSet(platform: .iPhone, files: [try localScreenshot("01_home.png", in: fixture)])],
                      stored: .filled(by: "the control"), owner: ScreenshotSetOwner.treatment, localization: .planned("en-US"))
        #expect(plan.lines == ["  upload  Story set · en-US · iPhone 6.9\"",
                               "            App Store Connect starts it with the control's screenshots",
                               "            replace them with 01_home.png"])
        let localization = fixture.fake.add("appStoreVersionExperimentTreatmentLocalizations", ["locale": "en-US"])
        let set = fixture.fake.addSet("APP_IPHONE_67", of: ("appStoreVersionExperimentTreatmentLocalization",
                                                            "appStoreVersionExperimentTreatmentLocalizations", localization),
                                      shots: [("control_1.png", "c1"), ("control_2.png", "c2")])
        let run = Run(asc: try fixture.session.connect())
        await run.record("en-US", id: localization)

        try await plan.changes[0].perform(run)

        #expect(fixture.fake.screenshots(inSet: set).map { $0.attributes["fileName"] as? String } == ["01_home.png"])
    }

    /// A set the plan read that changed before the change runs is left as
    /// it is.
    @Test func aReadSetThatChangedSinceThePlanIsLeftAsItIs() async throws {
        let fixture = try Fixture()
        let localization = fixture.fake.add("appStoreVersionLocalizations", ["locale": "en-US"],
                                            relationships: ["appStoreVersion": ("appStoreVersions", "ios")])
        var plan = Plan()
        plan.syncSets("iOS 1.2 · en-US", [LocalSet(platform: .iPhone, files: [try localScreenshot("01_home.png", in: fixture)])],
                      owner: ScreenshotSetOwner.version, localization: .existing(localization))
        let set = fixture.fake.addSet("APP_IPHONE_67", of: ("appStoreVersionLocalization", "appStoreVersionLocalizations", localization),
                                      shots: [("other.png", "o1")])

        let error = await #expect(throws: SetChangedSincePlan.self) {
            try await plan.changes[0].perform(Run(asc: try fixture.session.connect()))
        }

        #expect(error?.planned == ["upload 01_home.png", "keep 0, then order by file name"])
        #expect(error?.now == ["upload 01_home.png", "delete 1 no longer in the set", "keep 0, then order by file name"])
        #expect(fixture.fake.writes.isEmpty)
        #expect(fixture.fake.screenshots(inSet: set).map { $0.attributes["fileName"] as? String } == ["other.png"])
    }
}

@Suite struct FramerTests {
    @discardableResult
    func frame(_ fixture: Fixture) async throws -> Framer.Report {
        try await Commands.frameScreenshots(fixture.session, platforms: fixture.project.platforms, locales: fixture.project.locales)
    }

    @Test func framesEveryShotAtItsDisplaySizeThenReusesThem() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        let report = try await frame(fixture)
        #expect(fixture.console.output.contains("Framed 6 screenshots."))
        #expect(report.screenshots.map(\.name) == ["01_home.png", "02_list.png", "01_home.png", "02_list.png", "01_home.png", "01_home.png"])
        for screenshot in report.screenshots {
            #expect(try CGImage.read(from: screenshot.url).size == screenshot.platform.kind.screenshotSize)
        }
        #expect(try fixture.files(in: fixture.cache.framed).count == 6)

        let again = try fixture.again()
        let second = try await frame(again)
        #expect(again.console.output.contains("6 screenshots already framed."))
        #expect(second.screenshots.map(\.url.lastPathComponent) == report.screenshots.map(\.url.lastPathComponent))
    }

    /// Written beside a capture by the runner, they reach the theme in the
    /// capture's pixels and redraw that shot alone.
    @Test func highlightsReachTheThemeAndRedrawTheirShot() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        let before = try await frame(fixture)
        let raw = fixture.cache.raw(fixture.project.platforms[0], fixture.en).appending(path: "01_home.png")
        try Highlights([CGRect(x: 40, y: 80, width: 200, height: 120)]).write(for: raw)

        let again = try fixture.again()
        let after = try await frame(again)
        #expect(again.console.output.contains("Framed 1 screenshot; 5 were already framed."))
        let changed = zip(before.screenshots, after.screenshots).filter { $0.url.lastPathComponent != $1.url.lastPathComponent }
        #expect(changed.map { "\($1.platform.id) \($1.locale.code) \($1.name)" } == ["ios en 01_home.png"])
        let outlined = try CGImage.read(from: changed[0].1.url)
        #expect(Self.contains(SampleFrames.highlight, in: outlined))
        #expect(!Self.contains(SampleFrames.highlight, in: try CGImage.read(from: changed[0].0.url)))

        // Without highlights the file goes, and the frame is the first again.
        let copied = again.cache.raw(again.project.platforms[0], again.en).appending(path: "01_home.png")
        try Highlights([]).write(for: copied)
        #expect(!FileManager.default.fileExists(atPath: Highlights.url(for: copied).path))
        let third = try await frame(try again.again())
        #expect(third.screenshots[0].url.lastPathComponent == before.screenshots[0].url.lastPathComponent)
    }

    /// Whether any pixel is `color`, to within a step a channel.
    static func contains(_ color: CGColor, in image: CGImage) -> Bool {
        let target = color.components!.map { UInt8(($0 * 255).rounded()) }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: pixels.count, by: 4).contains { pixel in
            (0..<3).allSatisfy { abs(Int(pixels[pixel + $0]) - Int(target[$0])) <= 1 }
        }
    }

    @Test func aCaptionChangeRedrawsThatLocaleOnly() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        let before = try await frame(fixture)
        try fixture.updateCopy { $0.set("Hjem", field: .caption(.screenshot("home"), .headline), locale: fixture.da) }

        let again = try fixture.again()
        let after = try await frame(again)
        #expect(again.console.output.contains("Framed 2 screenshots; 4 were already framed."))
        let changed = zip(before.screenshots, after.screenshots).filter { $0.url.lastPathComponent != $1.url.lastPathComponent }
            .map { "\($1.platform.id) \($1.locale.code)" }
        #expect(changed == ["ios da", "macos da"])
        // The frames the index no longer names are gone.
        #expect(try again.files(in: again.cache.framed) == after.screenshots.map(\.url.lastPathComponent).sorted())
    }

    @Test func anUntranslatedLineShowsTheSourceWithAWarning() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        try fixture.updateCopy { $0.set("Everything here", field: .caption(.screenshot("list"), .subline), locale: fixture.en) }
        try await frame(fixture)
        #expect(fixture.console.output.contains(
            "warning: screenshot.list.subline · da is not translated, so the frame shows the source language"))
    }

    /// The review page frames what it can; the command stops for the rest.
    @Test func framesWhatItCanAndNamesWhatIsMissing() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        try FileManager.default.removeItem(at: fixture.cache.raw(fixture.project.platforms[0], fixture.da).appending(path: "02_list.png"))
        let framer = Framer(copy: try fixture.copy, cache: fixture.cache) { _ in }
        let report = try await framer.frame(platforms: fixture.project.platforms, locales: fixture.project.locales)
        #expect(report.screenshots.count == 5)
        #expect(report.problems.map(\.item) == [FramedItem(FrameSubject("list", on: .iPhone), locale: fixture.da)])
        #expect(report.problems.map(\.description) == ["no iPhone 6.9\" capture of list in da, for the iPhone 6.9\" list screenshot"])
        #expect(try fixture.files(in: fixture.cache.framed).count == 5)

        let error = await #expect(throws: Stopped.self) { try await frame(fixture) }
        #expect(error?.description.hasPrefix("Not every screenshot could be framed:\n  no iPhone 6.9\" capture of list in da") == true)
    }

    /// Framing some shots leaves the others' frames in the cache.
    @Test func framingSomeShotsKeepsTheRest() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        let all = try await frame(fixture)
        let framer = Framer(copy: try fixture.copy, cache: fixture.cache) { _ in }
        let one = try await framer.frame([FrameSubject("list", on: .iPhone)], locales: [fixture.da])
        #expect(one.screenshots.map(\.url) == all.screenshots.filter { $0.shot == "list" && $0.locale == fixture.da }.map(\.url))
        #expect(try fixture.files(in: fixture.cache.framed) == all.screenshots.map(\.url.lastPathComponent).sorted())
    }

    @Test func aShotWithoutAHeadlineStops() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        try fixture.updateCopy { $0.catalog.strings["screenshot.list.headline"] = nil }
        let error = await #expect(throws: Stopped.self) { try await frame(fixture) }
        #expect(error?.description.contains("screenshot.list.headline has no en value") == true)
    }

    @Test func jpegOutputIsJPEG() async throws {
        let fixture = try Fixture(themes: .frames)
        fixture.project.output = .jpeg(quality: 0.85)
        try fixture.writeCaptures()
        let report = try await frame(fixture)
        #expect(report.screenshots.allSatisfy { $0.name.hasSuffix(".jpg") && $0.url.pathExtension == "jpg" })
        #expect(try Data(contentsOf: report.screenshots[0].url).prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func withoutAThemeACaptureMustBeASizeAppStoreConnectTakes() async throws {
        let fixture = try Fixture()
        try fixture.writeCaptures()
        let raw = fixture.cache.raw(fixture.project.platforms[1], fixture.en).appending(path: "01_home.png")
        let small = Canvas(size: CGSize(width: 1600, height: 1200))
        try ImageFormat.png.encode(small.image()).write(to: raw)
        let error = await #expect(throws: Stopped.self) { try await frame(fixture) }
        #expect(error?.description.contains("Mac 01_home.png in en is 1600 × 1200, which App Store Connect does not take") == true)
    }

    @Test func theSampleThemeDrawsAsRecorded() throws {
        let capture = Canvas(size: CGSize(width: 1320, height: 2868))
        drawGradient(in: capture.context, rect: capture.bounds, top: .hex(0xF2F2F7), bottom: .hex(0xC7C7CC))
        capture.context.setFillColor(.hex(0x0A84FF))
        capture.context.fill(CGRect(x: 80, y: 2300, width: 1160, height: 300))
        let shot = FramedShot(shot: "home", position: 1, count: 2, platform: .iPhone, locale: StoreLocale("en", store: "en-US"),
                              caption: Caption(kicker: "Inbox", headline: "Every alert, *accounted for.*", subline: "Repeats merged."),
                              images: [.capture("home", on: .iPhone): capture.image()])
        let canvas = Canvas(size: Platform.Kind.iPhone.screenshotSize)
        try SampleFrames().render(shot, on: canvas)
        try Golden.check(canvas.image(), named: "sample-iphone")
    }
}

@Suite struct VideosTests {
    func push(_ fixture: Fixture, _ options: WriteOptions = apply) async throws {
        try await Commands.pushVideos(fixture.session, locales: "en", options: options, pollInterval: .milliseconds(1))
    }

    func render(_ fixture: Fixture) async throws -> VideoRenderer.Report {
        try await Commands.renderVideos(fixture.session, locales: [fixture.en])
    }

    @Test func rendersALoopAtTheAssetsSize() async throws {
        let fixture = try Fixture(themes: .videos)
        try fixture.writeCaptures()
        let report = try await render(fixture)
        #expect(fixture.console.output.contains("Rendering the product page header video in en…"))
        let track = try #require(try await AVURLAsset(url: report.videos[0].url).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 3840, height: 1646))
        #expect(abs(try await track.load(.timeRange).duration.seconds - 1) < 0.05)

        let again = try fixture.again()
        #expect(try await render(again).videos[0].url.lastPathComponent == report.videos[0].url.lastPathComponent)
        #expect(again.console.output.contains("1 video already rendered."))
    }

    /// Each stale video is drawn and encoded in turn, after all are checked.
    @Test func rendersEveryStaleVideoInTurn() async throws {
        let fixture = try Fixture(themes: .videos)
        try fixture.writeCaptures()
        let da = try #require(fixture.project.locales.first { $0.code == "da" })
        let report = try await Commands.renderVideos(fixture.session, locales: [fixture.en, da])
        #expect(report.drawn == 2)
        #expect(Set(report.videos.map(\.url)).count == 2)
        for video in report.videos {
            let track = try #require(try await AVURLAsset(url: video.url).loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalSize) == CGSize(width: 3840, height: 1646))
        }
        let output = fixture.console.output
        let en = try #require(output.range(of: "Rendering the product page header video in en…"))
        let danish = try #require(output.range(of: "Rendering the product page header video in da…"))
        #expect(en.lowerBound < danish.lowerBound)
    }

    @Test func uploadsWaitsAndPlacesThenFindsNothingToChange() async throws {
        let fixture = try Fixture(themes: .videos)
        try fixture.writeCaptures()
        try await Commands.pushMetadata(fixture.session, locales: "en", platforms: "ios", options: apply)

        try await push(fixture)

        let video = try #require(fixture.fake.all("appAssetLibraryVideos").first)
        #expect(video.attributes["state"] as? String == "COMPLETE")
        #expect(video.attributes["fileName"] as? String == "header.mp4")
        #expect(video.attributes["previewFrameTimeCode"] as? String == "00:00:00:15")
        #expect((video.attributes["referenceName"] as? String)?.hasPrefix("example-header-en-") == true)
        let placement = try #require(fixture.fake.all("appAssetLibraryPlacements").first)
        #expect(placement.attributes["placementType"] as? String == "PRODUCT_PAGE_HEADER_ASSET")
        #expect(placement.relationships["video"]?.id == video.id)

        fixture.fake.clearWrites()
        let again = try fixture.again()
        try await push(again)
        #expect(again.console.output.contains("Nothing to change."))
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func aNewCaptionReplacesThePlacement() async throws {
        let fixture = try Fixture(themes: .videos)
        try fixture.writeCaptures()
        try await Commands.pushMetadata(fixture.session, locales: "en", platforms: "ios", options: apply)
        try await push(fixture)
        try fixture.updateCopy { $0.set("Hear it first", field: .caption(.video(.header), .headline), locale: fixture.en) }
        let again = try fixture.again()
        try await push(again)
        #expect(fixture.fake.all("appAssetLibraryVideos").count == 2)
        let placements = fixture.fake.all("appAssetLibraryPlacements")
        #expect(placements.count == 1)
        #expect(placements[0].relationships["video"]?.id == fixture.fake.all("appAssetLibraryVideos")[1].id)
        #expect(again.console.output.contains("replaces what the slot holds"))
    }

    @Test func aLocaleTheVersionLacksIsAWarning() async throws {
        let fixture = try Fixture(themes: .videos)
        try fixture.writeCaptures()
        try await push(fixture, dryRun)
        #expect(fixture.console.output.contains("warning: iOS 1.2 has no en-US localization, so its product page header video is left out"))
    }

    /// Each check stops the run before anything is encoded.
    @Test(arguments: [
        ("the caption leaves the safe area", 0.0, (0.75, 0.2, 0.08)),
        ("device 1 floats over the caption", 0.32, (0.45, 0.3, 0.08)),
        ("device 1: home would be enlarged from 1320 to 1920 px", 0.32, (0.75, 0.0, 0.5)),
    ] as [(String, Double, (CGFloat, CGFloat, CGFloat))])
    func aLayoutMistakeStops(problem: String, captionTop: Double, phone: (CGFloat, CGFloat, CGFloat)) async throws {
        let fixture = try Fixture(themes: .videos)
        var motion = SampleMotion(shots: ["home", "list"], phone: phone)
        motion.column.top = captionTop
        fixture.project.videos = motion
        try fixture.writeCaptures()
        let error = await #expect(throws: Stopped.self) { try await render(fixture) }
        #expect(error?.description.contains("product page header · en: \(problem)") == true, "\(error?.description ?? "")")
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.videos.path))
    }

    @Test func aMissingCaptureStops() async throws {
        let fixture = try Fixture(themes: .videos)
        try fixture.writeCapture(.iPhone, fixture.en, "home")
        let error = await #expect(throws: Stopped.self) { try await render(fixture) }
        #expect(error?.description.contains("product page header · en: no iPhone 6.9\" capture of list") == true)
    }

    @Test func timeCodesCountFrames() {
        #expect(VideosPlanner.timeCode(seconds: 0, fps: 30) == "00:00:00:00")
        #expect(VideosPlanner.timeCode(seconds: 1.5, fps: 30) == "00:00:01:15")
        #expect(VideosPlanner.timeCode(seconds: 3725.1, fps: 30) == "01:02:05:03")
    }
}

@Suite struct HousekeepingTests {
    @Test func exportCopiesTheCurrentSet() async throws {
        let fixture = try Fixture(themes: [.frames, .videos])
        fixture.project.renders = [Render("home-site", .capture("home", on: .mac)), Render("settings", .capture("settings", on: .iPhone)),
                                   Render("basket", .component(Component("basket", state: "full"), on: .iPhone)),
                                   Render("share", .test("ExampleUITests/Renders/testShare", scene: Shot("share", variant: "mail"), on: .iPhone))]
        try fixture.writeCaptures()
        let destination = fixture.root.appending(path: "export")
        try await Commands.export(fixture.session, to: destination.path)
        let files = try FileManager.default.subpathsOfDirectory(atPath: destination.path).filter { $0.contains(".") }.sorted()
        #expect(files == ["ios/da/01_home.png", "ios/da/02_list.png", "ios/en/01_home.png", "ios/en/02_list.png",
                          "macos/da/01_home.png", "macos/en/01_home.png",
                          "renders/ios/basket.png", "renders/ios/settings.png", "renders/ios/share.png", "renders/macos/home-site.png",
                          "videos/da/header.mp4", "videos/en/header.mp4"])
        #expect(fixture.console.output.contains("Exported 12 files to"))
    }

    /// The flags narrow the screenshots and renders to their platforms and
    /// the screenshots and videos to their locales.
    @Test func exportCopiesOnlyThePlatformsAndLocalesNamed() async throws {
        let fixture = try Fixture(themes: [.frames, .videos])
        fixture.project.renders = [Render("home-site", .capture("home", on: .mac)), Render("settings", .capture("settings", on: .iPhone))]
        try fixture.writeCaptures()
        let destination = fixture.root.appending(path: "export")
        try await Commands.export(fixture.session, to: destination.path, platforms: "ios", locales: "da")
        let files = try FileManager.default.subpathsOfDirectory(atPath: destination.path).filter { $0.contains(".") }.sorted()
        #expect(files == ["ios/da/01_home.png", "ios/da/02_list.png", "renders/ios/settings.png", "videos/da/header.mp4"])
    }

    /// Videos belong to the iOS product page, so a Mac export leaves them out.
    @Test func exportWithoutAnIOSPlatformLeavesOutTheVideos() async throws {
        let fixture = try Fixture(themes: [.frames, .videos])
        try fixture.writeCaptures()
        let destination = fixture.root.appending(path: "export")
        try await Commands.export(fixture.session, to: destination.path, platforms: "macos")
        let files = try FileManager.default.subpathsOfDirectory(atPath: destination.path).filter { $0.contains(".") }.sorted()
        #expect(files == ["macos/da/01_home.png", "macos/en/01_home.png"])
    }

    @Test func exportStopsOnAnUnknownLocale() async throws {
        let fixture = try Fixture(themes: .frames)
        await #expect(throws: (any Error).self) {
            try await Commands.export(fixture.session, to: fixture.root.appending(path: "export").path, locales: "xx")
        }
    }

    /// A relative directory is inside the one the command runs in, not beside it.
    @Test func exportResolvesARelativeDirectoryInsideTheBase() async throws {
        let fixture = try Fixture(themes: [.frames, .videos])
        try fixture.writeCaptures()
        let base = fixture.root.appending(path: "app")
        try await Commands.export(fixture.session, to: "build/export", from: base.path)
        #expect(FileManager.default.fileExists(atPath: base.appending(path: "build/export/videos/en/header.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "build").path))
    }

    /// A render nothing has captured yet stops the export and says which.
    @Test func exportNamesARenderNotCapturedYet() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        fixture.project.renders = [Render("settings", .capture("settings", on: .iPhone))]
        let error = await #expect(throws: Stopped.self) {
            try await Commands.export(fixture.session, to: fixture.root.appending(path: "export").path)
        }
        #expect(error?.description == "Not captured yet, so `screenshots capture` first: settings.")
    }

    @Test func pruneKeepsCapturesAndCurrentFrames() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        let report = try await Commands.frameScreenshots(fixture.session, platforms: fixture.project.platforms,
                                                         locales: fixture.project.locales)
        try fixture.write(Data(count: 1000), to: "cache/com.example.app/derived/Build/big")
        try fixture.write(Data(count: 10), to: "cache/com.example.app/framed/stale.png")
        try Commands.cacheSize(fixture.session)
        #expect(fixture.console.output.contains("build"))
        try Commands.pruneCache(fixture.session)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.derivedData.path))
        #expect(try fixture.files(in: fixture.cache.framed) == report.screenshots.map(\.url.lastPathComponent).sorted())
        #expect(FileManager.default.fileExists(atPath: fixture.cache.raw(fixture.project.platforms[0], fixture.en).path))
        #expect(fixture.console.output.contains("Freed"))
    }
}
