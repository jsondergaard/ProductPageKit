import Foundation
import Testing
@testable import ProductPageKitCore

@Suite struct FieldTests {
    /// Apple's caps. App Store Connect enforces them at submission.
    @Test func capsAreApples() {
        #expect(Field.name.maxLength == 30)
        #expect(Field.subtitle.maxLength == 30)
        #expect(Field.keywords.maxLength == 100)
        #expect(Field.promotionalText.maxLength == 170)
        #expect(Field.description.maxLength == 4000)
        #expect(Field.reviewNotes.maxLength == 4000)
        #expect(Field.whatsNew("1.0").maxLength == 4000)
        #expect(Field.productReviewNote.maxLength == 4000)
    }

    @Test func onlyReviewNotesAreNotTranslated() {
        #expect(Field.listing.allSatisfy { $0.isTranslatable })
        #expect(!Field.reviewNotes.isTranslatable)
        #expect(!Field.productReviewNote.isTranslatable)
    }
}

@Suite struct ProjectTests {
    @Test func storePlatformsAreUniqueInOrder() {
        var example = project()
        example.platforms = [.mac(), .iPhone(), .iPad()]
        #expect(example.storePlatforms == [.macOS, .iOS])
    }

    /// iPhone Duo is a set of its own on the iOS page, framed on its inner
    /// display opened flat, and taking either display's captures.
    @Test func iPhoneDuoIsAnIOSSetOfItsOwn() {
        var example = project()
        example.platforms = [.iPhone(), .iPhoneDuo()]
        #expect(example.storePlatforms == [.iOS])
        #expect(example.problems().isEmpty)
        let duo = Platform.Kind.iPhoneDuo
        #expect(duo.displayType == "APP_IPHONE_DUO")
        #expect(duo.screenshotSize == CGSize(width: 2853, height: 2007))
        #expect(duo.acceptedSizes == [CGSize(width: 2853, height: 2007), CGSize(width: 2034, height: 1398),
                                      CGSize(width: 2007, height: 2853), CGSize(width: 1398, height: 2034)])
        #expect(duo.bezel == .iPhoneDuo)
    }

    @Test func duplicateLocalesAndPlatformsAreProblems() {
        var example = project(locales: [StoreLocale("en", store: "en-US"), StoreLocale("en", store: "en-GB")])
        example.platforms = [.iPhone(), .iPhone()]
        #expect(example.problems() == ["locale en is listed twice", "platform ios is listed twice"])
    }

    @Test func videosNeedAnIOSPlatform() {
        var example = project()
        example.platforms = [.mac()]
        example.videos = PlainMotion(assets: [CreativeAsset(.header, poster: 0, devices: [])])
        #expect(example.problems().contains("header and search videos go on the iOS version, and no iOS platform is configured"))
    }

    @Test func localeIdentifierUsesAnUnderscore() {
        #expect(StoreLocale("en", store: "en-US").localeIdentifier == "en_US")
    }
}

@Suite struct EnvironmentTests {
    @Test func parsesDotEnvLines() {
        let values = Environment.parse("""
            # comment
            ASC_KEY_ID=ABC123
            export ASC_ISSUER_ID = "issuer"
            QUOTED='single'
            not a pair

            EMPTY=
            """)
        #expect(values == ["ASC_KEY_ID": "ABC123", "ASC_ISSUER_ID": "issuer", "QUOTED": "single", "EMPTY": ""])
    }

    @Test func theProcessEnvironmentWinsOverTheFile() throws {
        let repository = try TemporaryRepository()
        try repository.write("A=file\nB=file\n", to: ".env")
        let environment = try Environment.load(root: repository.url, process: ["B": "shell"])
        #expect(environment["A"] == "file")
        #expect(environment["B"] == "shell")
    }

    @Test func anEmptyValueIsMissing() {
        #expect(Environment(values: ["A": ""])["A"] == nil)
    }
}

@Suite struct RepositoryTests {
    @Test func findsTheRootAboveADirectory() throws {
        let repository = try TemporaryRepository()
        let nested = repository.url.appending(path: "Tools/ProductPage")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(try Repository.root(from: nested).standardizedFileURL.path == repository.url.standardizedFileURL.path)
    }

    @Test func aWorktreesGitFileCounts() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "gitdir: /elsewhere".write(to: directory.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(try Repository.root(from: directory).standardizedFileURL.path == directory.standardizedFileURL.path)
    }
}

@Suite struct PlatformTests {
    @Test func storeShotsAreNumberedAndOthersKeepTheirName() {
        let iPhone = Platform.iPhone(shots: ["inbox", Shot("library", variant: "pro")])
        #expect(iPhone.fileName(for: "inbox") == "01_inbox")
        #expect(iPhone.fileName(for: Shot("library", variant: "pro")) == "02_library-pro")
        #expect(iPhone.fileName(for: Shot("library", variant: "emby")) == "library-emby")
        #expect(iPhone.fileName(for: "panel") == "panel")
    }

    @Test func shotListsAreChecked() {
        var example = project()
        example.platforms = [
            .iPhone(shots: ["inbox", "inbox"]),
            .iPad(shots: (1...11).map { Shot("scene\($0)") }),
            .mac(shots: ["inbox"]),
        ]
        example.reviewScreenshots = [.inAppPurchases(test: "A/b()"), .inAppPurchases(test: "A/c()")]
        #expect(example.problems() == [
            "Mac has shots and no window size",
            "iPad 13\" lists 11 shots, and App Store Connect takes 10",
            "iPhone 6.9\" lists inbox twice",
            "the in-app purchases review screenshot is listed twice",
        ])
    }

    @Test func theCacheKeepsEachAppApartAndSharesTheScreen() {
        let cache = Cache(bundleID: "com.example.app", root: URL(filePath: "/cache"))
        #expect(cache.raw(.iPhone(), StoreLocale("en", store: "en-US")).path == "/cache/com.example.app/raw/ios/en")
        #expect(cache.review(.mac(), .inAppPurchases).path == "/cache/com.example.app/review/macos/inAppPurchases.png")
        #expect(cache.lock(.iPhone()).path == "/cache/com.example.app/locks/ios.lock")
        #expect(cache.lock(.mac()).path == "/cache/locks/macos.lock")
    }
}
