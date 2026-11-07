import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKitCore
import ProductPageKitFrames

/// A theme whose feature graphic draws the phone's first capture.
struct GraphicFrames: FrameTheme {
    func sources(for frame: FrameSubject) -> [FrameSource] {
        frame.platform == .featureGraphic ? [.capture("home", on: .androidPhone)] : [.capture(frame.shot, on: frame.platform)]
    }

    func render(_ shot: FramedShot, on canvas: Canvas) throws {}
}

func playProject(locales: [StoreLocale] = [StoreLocale("en", store: "en-US"), StoreLocale("da", store: "da")]) -> Project {
    var example = project(locales: locales)
    example.platforms += [.androidPhone(.emulator("phone"), shots: ["home"]), .featureGraphic()]
    example.frames = GraphicFrames()
    example.android = AndroidApp(build: ["./gradlew assembleDebug"], apk: "app/build/app-debug.apk",
                                 applicationID: "com.example.app.dev", activity: ".MainActivity")
    example.play = GooglePlay(packageName: "com.example.app")
    return example
}

@Suite struct PlayLanguageTests {
    /// Spectati's locales, which Google Play lists under their own codes.
    @Test func appStoreLocalesMapToPlayLanguages() {
        let expected: [String: String] = [
            "en-US": "en-US", "ar-SA": "ar", "cs": "cs-CZ", "da": "da-DK", "de-DE": "de-DE", "el": "el-GR", "es-ES": "es-ES",
            "es-MX": "es-419", "fi": "fi-FI", "fr-FR": "fr-FR", "fr-CA": "fr-CA", "hr": "hr", "hu": "hu-HU", "id": "id",
            "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR", "no": "no-NO", "nl-NL": "nl-NL", "pl": "pl-PL", "pt-BR": "pt-BR",
            "pt-PT": "pt-PT", "ro": "ro", "sk": "sk", "sv": "sv-SE", "th": "th", "tr": "tr-TR", "uk": "uk", "vi": "vi",
            "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "he": "iw-IL",
        ]
        for (store, play) in expected {
            #expect(StoreLocale("x", store: store).playLanguage == play, "\(store)")
        }
    }

    @Test func noTwoAppStoreLocalesShareAPlayLanguage() {
        let languages = Array(StoreLocale.playLanguages.values)
        #expect(Set(languages).count == languages.count)
    }

    @Test func aLocaleGooglePlayHasNoLanguageForIsAProblem() {
        let example = playProject(locales: [StoreLocale("en", store: "en-US"), StoreLocale("tlh", store: "tlh")])
        #expect(example.problems() == ["locale tlh is App Store Connect's tlh, which has no Google Play language"])
        var appStoreOnly = example
        appStoreOnly.play = nil
        appStoreOnly.platforms = appStoreOnly.platforms(in: .appStore)
        #expect(appStoreOnly.problems().isEmpty)
    }
}

@Suite struct PlayFieldTests {
    @Test func capsAreGooglePlays() {
        #expect(Field.playTitle.maxLength == 30)
        #expect(Field.playShortDescription.maxLength == 80)
        #expect(Field.playFullDescription.maxLength == 4000)
        #expect(Field.playListing.allSatisfy { $0.store == .googlePlay && $0.isTranslatable && $0.isRequired })
        #expect(Field.name.store == .appStore)
    }

    @Test func playCopyIsCheckedOnlyForAProjectOnGooglePlay() {
        var copy = StoreCopy(project: playProject(), catalog: StringCatalog(sourceLanguage: "en"))
        let en = StoreLocale("en", store: "en-US"), da = StoreLocale("da", store: "da")
        #expect(copy.fields.map(\.key).starts(with: Field.listing.map(\.key) + Field.playListing.map(\.key)))
        #expect(copy.problems().contains(.error("play.shortDescription is missing")))
        copy.set("Example", field: .playTitle, locale: en)
        copy.set("Alerts that ring.", field: .playShortDescription, locale: en)
        copy.set(String(repeating: "x", count: 81), field: .playShortDescription, locale: da)
        copy.set(String(repeating: "x", count: 4001), field: .playFullDescription, locale: en)
        #expect(copy.problems().contains(.error("play.shortDescription · da: 81 characters, Google Play caps Google Play short description at 80")))
        #expect(copy.problems().contains(.error("play.fullDescription · en: 4001 characters, Google Play caps Google Play full description at 4000")))

        var appStore = project()
        appStore.play = nil
        #expect(!StoreCopy(project: appStore, catalog: StringCatalog(sourceLanguage: "en")).fields.contains(.playTitle))
    }
}

@Suite struct PlayImageTests {
    func facts(_ width: Int, _ height: Int, alpha: Bool = false, format: ImageFacts.Format = .png, bytes: Int = 1000) -> ImageFacts {
        ImageFacts(size: CGSize(width: width, height: height), hasAlpha: alpha, format: format, bytes: bytes)
    }

    @Test func phoneAndTabletScreenshotsAreSixteenByNineWithinTheRange() {
        for type in [PlayImageType.phoneScreenshots, .sevenInchScreenshots, .tenInchScreenshots] {
            #expect(type.accepts(CGSize(width: 1080, height: 1920)))
            #expect(type.accepts(CGSize(width: 3840, height: 2160)))
            #expect(type.accepts(CGSize(width: 576, height: 324)))
            #expect(!type.accepts(CGSize(width: 1080, height: 2400)), "20:9 is not 16:9")
            #expect(!type.accepts(CGSize(width: 288, height: 162)), "under 320")
            #expect(!type.accepts(CGSize(width: 4096, height: 2304)), "over 3840")
        }
    }

    @Test func tvWearAndGraphicsHaveTheirOwnSizes() {
        #expect(PlayImageType.tvScreenshots.accepts(CGSize(width: 1920, height: 1080)))
        #expect(PlayImageType.tvScreenshots.accepts(CGSize(width: 3840, height: 2160)))
        #expect(!PlayImageType.tvScreenshots.accepts(CGSize(width: 1280, height: 720)))
        #expect(PlayImageType.wearScreenshots.accepts(CGSize(width: 454, height: 454)))
        #expect(!PlayImageType.wearScreenshots.accepts(CGSize(width: 320, height: 320)))
        #expect(!PlayImageType.wearScreenshots.accepts(CGSize(width: 454, height: 500)))
        #expect(PlayImageType.featureGraphic.accepts(CGSize(width: 1024, height: 500)))
        #expect(!PlayImageType.featureGraphic.accepts(CGSize(width: 2048, height: 1000)))
        #expect(PlayImageType.tvBanner.accepts(CGSize(width: 1280, height: 720)))
        #expect(!PlayImageType.tvBanner.accepts(CGSize(width: 1920, height: 1080)))
    }

    @Test func everySlotTakesTheCanvasItIsDrawnOn() {
        for type in PlayImageType.allCases { #expect(type.accepts(type.canvas), "\(type)") }
        for kind in Platform.Kind.allCases { #expect(kind.accepts(kind.screenshotSize), "\(kind)") }
    }

    @Test func problemsNameAlphaSizeFormatAndWeight() {
        #expect(PlayImageType.phoneScreenshots.problems(facts(1080, 1920)).isEmpty)
        #expect(PlayImageType.phoneScreenshots.problems(facts(1080, 1920, format: .jpeg)).isEmpty)
        #expect(PlayImageType.phoneScreenshots.problems(facts(1080, 1920, alpha: true))
            == ["is a PNG with an alpha channel, and Google Play takes 24-bit PNG without one"])
        #expect(PlayImageType.featureGraphic.problems(facts(1024, 512)) == ["is 1024 × 512, and Google Play takes 1024 × 500"])
        #expect(PlayImageType.phoneScreenshots.problems(facts(1080, 1920, format: .other)) == ["is neither PNG nor JPEG"])
        #expect(PlayImageType.phoneScreenshots.problems(facts(1080, 1920, bytes: 9 << 20))
            == ["is 9 MB, and Google Play takes up to 8 MB"])
        #expect(PlayImageType.featureGraphic.problems(facts(1024, 500, bytes: 9 << 20)).isEmpty)
    }

    /// What the framer writes for Google Play: a PNG without alpha, which
    /// the rules read back from the file.
    @Test func anOpaqueImageWritesAPNGWithoutAlpha() throws {
        let canvas = Canvas(size: CGSize(width: 1080, height: 1920))
        canvas.context.setFillColor(.hex(0x336699, alpha: 0.5))
        canvas.context.fill(canvas.bounds)
        let translucent = try #require(ImageFacts(try ImageFormat.png.encode(canvas.image())))
        #expect(translucent.hasAlpha && translucent.format == .png)
        let opaque = try #require(ImageFacts(try ImageFormat.png.encode(canvas.image().opaque())))
        #expect(!opaque.hasAlpha && opaque.size == CGSize(width: 1080, height: 1920))
        #expect(PlayImageType.phoneScreenshots.problems(opaque).isEmpty)
        #expect(ImageFacts(Data("not an image".utf8)) == nil)
    }
}

@Suite struct PlayPlatformTests {
    @Test func androidPlatformsAndGraphicsAreGooglePlays() {
        let example = playProject()
        #expect(example.problems().isEmpty)
        #expect(example.platforms(in: .googlePlay).map(\.id) == ["android", "feature"])
        #expect(example.storePlatforms == [.iOS, .macOS])
        #expect(Platform.Kind.androidPhone.storePlatform == nil && Platform.Kind.androidPhone.displayType == nil)
        #expect(Platform.Kind.androidTV.playImageType == .tvScreenshots)
        #expect(Platform.Kind.iPhone.playImageType == nil)
        #expect(Platform.Kind.wear.maximumShots == 8 && Platform.Kind.featureGraphic.maximumShots == 1)
        #expect(Platform.Kind.featureGraphic.bezel == nil && Platform.Kind.wear.bezel == .wear)
        // The graphic draws from the phone, so only the phone is captured.
        #expect(example.captures(on: .androidPhone) == ["home"])
        #expect(example.captures(on: .featureGraphic).isEmpty)
    }

    @Test func androidAndPlayConfigurationIsChecked() {
        var example = playProject()
        example.play = nil
        example.android = nil
        example.frames = nil
        #expect(example.problems() == [
            "the Android phone, feature graphic go to Google Play, and Project.play is not set",
            "the Android phone is captured on Android, and Project.android is not set",
            "the feature graphic is drawn by a theme, and the project has none",
        ].sorted())

        var crowded = playProject(locales: [StoreLocale("en", store: "en-US"), StoreLocale("es", store: "es-MX"),
                                            StoreLocale("es-419", store: "es-MX")])
        crowded.platforms[2].shots = (1...9).map { Shot("s\($0)") }
        #expect(crowded.problems().contains("locales es and es-419 are both Google Play's es-419"))
        #expect(crowded.problems().contains("Android phone lists 9 shots, and Google Play takes 8"))
    }

    @Test func aDrawnGraphicCannotBeASource() {
        struct SelfDrawn: FrameTheme {
            func sources(for frame: FrameSubject) -> [FrameSource] { [.capture(frame.shot, on: frame.platform)] }
            func render(_ shot: FramedShot, on canvas: Canvas) throws {}
        }
        var example = playProject()
        example.frames = SelfDrawn()
        #expect(example.problems() == [
            "the feature graphic featureGraphic screenshot draws the feature graphic capture of featureGraphic, and the feature graphic is drawn, not captured",
        ])
    }

    @Test func anAndroidPlatformExportsNoComponents() {
        struct Components: FrameTheme {
            func sources(for frame: FrameSubject) -> [FrameSource] {
                frame.platform == .featureGraphic ? [.component(Component("card"), on: .androidPhone)] : [.capture(frame.shot, on: frame.platform)]
            }
            func render(_ shot: FramedShot, on canvas: Canvas) throws {}
        }
        var example = playProject()
        example.frames = Components()
        #expect(example.problems() == ["the Android phone exports no components, and something draws one from it"])
    }
}
