import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKit
import ProductPageKitPlay
import ProductPageKitTestSupport

/// A project on both stores: iPhone for the App Store, an Android phone for
/// Google Play, and the `play.` copy in English and Danish.
func playFixture() throws -> Fixture {
    let fixture = try Fixture(themes: .frames)
    fixture.project.platforms = [.iPhone(shots: ["home", "list"]), .androidPhone(.emulator("phone"), shots: ["home", "inbox"])]
    fixture.project.android = AndroidApp(build: [], apk: "app.apk", applicationID: "com.example.app.dev", activity: ".MainActivity")
    fixture.project.play = GooglePlay(packageName: FakeGooglePlay.packageName)
    try fixture.writeCatalog()
    try fixture.updateCopy { copy in
        for (locale, title, short, full) in [(fixture.en, "Example", "Alerts that ring.", "Every alert rings until you answer."),
                                             (fixture.da, "Eksempel", "Alarmer der ringer.", "Hver alarm ringer, til du svarer.")] {
            copy.set(title, field: .playTitle, locale: locale)
            copy.set(short, field: .playShortDescription, locale: locale)
            copy.set(full, field: .playFullDescription, locale: locale)
        }
    }
    return fixture
}

@Suite struct PlayMetadataTests {
    func push(_ fixture: Fixture, options: WriteOptions = apply) async throws {
        try await Commands.pushPlayMetadata(fixture.session, locales: "", options: options)
    }

    @Test func eachListingIsCreatedInOneEditThenNothingChanges() async throws {
        let fixture = try playFixture()
        try await push(fixture)
        #expect(fixture.play.live.listings["en-US"] == PlayListing(language: "en-US", title: "Example", shortDescription: "Alerts that ring.",
                                                                    fullDescription: "Every alert rings until you answer."))
        #expect(fixture.play.live.listings["da-DK"]?.title == "Eksempel")
        #expect(fixture.play.commitQueries == [""])
        #expect(fixture.console.output.contains("  create  Google Play · da-DK"))
        #expect(fixture.console.output.contains("Committed. Google Play reviews the changes before they go live."))

        try await push(fixture)
        #expect(fixture.console.output.hasSuffix("Nothing to change."))
        #expect(fixture.play.commitQueries.count == 1)
        #expect(fixture.play.openEdits == 0)
    }

    @Test func onlyAChangedFieldIsPatched() async throws {
        var live = FakeGooglePlay.State()
        live.listings["en-US"] = PlayListing(language: "en-US", title: "Example", shortDescription: "Old.",
                                             fullDescription: "Every alert rings until you answer.")
        let fixture = try playFixture()
        fixture.play.reset(to: live)
        try await Commands.pushPlayMetadata(fixture.session, locales: "en", options: apply)
        #expect(fixture.console.output.contains("            Google Play short description: Old. → Alerts that ring."))
        #expect(!fixture.console.output.contains("Google Play title"))
        #expect(fixture.play.live.listings["en-US"]?.shortDescription == "Alerts that ring.")
        #expect(fixture.play.requests.contains("PATCH /androidpublisher/v3/applications/com.example.app/edits/edit-2/listings/en-US"))
    }

    @Test func aDryRunDeletesItsEdit() async throws {
        let fixture = try playFixture()
        try await push(fixture, options: try WriteOptions.parse(["--dry-run"]))
        #expect(fixture.console.output.contains("Dry run: 2 changes, nothing written."))
        #expect(fixture.play.live.listings.isEmpty)
        #expect(fixture.play.openEdits == 0)
    }

    /// Google Play needs every field of a new listing, so a language whose
    /// copy is not all translated waits.
    @Test func aNewListingWithoutAllItsCopyIsNotCreated() async throws {
        var live = FakeGooglePlay.State()
        live.listings["de-AT"] = PlayListing(language: "de-AT", title: "Beispiel", shortDescription: nil, fullDescription: nil)
        let fixture = try playFixture()
        fixture.play.reset(to: live)
        try fixture.updateCopy { copy in copy.set("", field: .playFullDescription, locale: fixture.da) }
        try await push(fixture)
        #expect(fixture.console.output.contains("warning: Google Play · da-DK has no listing, and the catalog has no Google Play full description to upload in da, so it is not created"))
        #expect(fixture.console.output.contains("warning: Google Play lists de-AT, which no configured locale is; left as it is"))
        #expect(fixture.play.live.listings.keys.sorted() == ["de-AT", "en-US"])
    }

    @Test func managedPublishingLeavesTheChangesToSend() async throws {
        let fixture = try playFixture()
        fixture.project.play?.sendsForReview = false
        try await push(fixture)
        #expect(fixture.play.commitQueries == ["changesNotSentForReview=true"])
        #expect(fixture.console.output.contains("Send the changes for review from the Play Console's Publishing overview."))
    }

    @Test func aProjectWithoutGooglePlayStops() async throws {
        let fixture = try Fixture()
        await #expect { try await push(fixture) } throws: { "\($0)" == "The project has no Google Play listing (Project.play)." }
    }
}

@Suite struct PlayScreenshotsTests {
    func push(_ fixture: Fixture, locales: String = "en") async throws {
        try await Commands.pushPlayScreenshots(fixture.session, platforms: "", locales: locales, options: apply)
    }

    func phone(_ fixture: Fixture, _ language: String = "en-US") -> [FakeGooglePlay.Image] {
        fixture.play.live.images[language]?[.phoneScreenshots] ?? []
    }

    @Test func framedImagesUploadOpaqueInOrderThenNothingChanges() async throws {
        let fixture = try playFixture()
        try fixture.writeCaptures()
        try await push(fixture, locales: "")
        #expect(phone(fixture).count == 2)
        #expect(phone(fixture, "da-DK").count == 2)
        for image in phone(fixture) {
            let facts = try #require(ImageFacts(image.data))
            #expect(!facts.hasAlpha && facts.size == CGSize(width: 1080, height: 1920))
        }
        // The App Store's iPhone set is not Google Play's.
        #expect(fixture.fake.writes.isEmpty)

        try await push(fixture, locales: "")
        #expect(fixture.console.output.hasSuffix("Nothing to change."))
        #expect(fixture.play.openEdits == 0)
    }

    /// Google Play cannot reorder a slot, so everything from the first
    /// changed image is uploaded again and what comes before is kept.
    @Test func aChangedSecondImageKeepsTheFirst() async throws {
        let fixture = try playFixture()
        try fixture.writeCaptures()
        try await push(fixture)
        let first = phone(fixture)[0]
        try fixture.writeCapture(.androidPhone, fixture.en, "inbox", shade: 7)
        try await push(fixture)
        #expect(phone(fixture)[0] == first)
        #expect(phone(fixture).count == 2)
        #expect(fixture.console.output.contains("            delete 1 after the first 1"))
        #expect(fixture.console.output.contains("            upload 02_inbox.png"))
    }

    @Test func aFailedUploadCommitsNothing() async throws {
        let fixture = try playFixture()
        try fixture.writeCaptures()
        fixture.play.fail("POST", "/phoneScreenshots")
        await #expect(throws: (any Error).self) { try await push(fixture) }
        #expect(fixture.console.output.contains("Nothing was committed: the edit and every change in it are discarded."))
        #expect(fixture.play.live.images.isEmpty)
        #expect(fixture.play.openEdits == 0)
        #expect(fixture.play.commitQueries.isEmpty)
    }

    @Test func anImageGooglePlayWouldRefuseStopsBeforeAnyRequest() async throws {
        struct Tall: FrameTheme {
            func canvasSize(for platform: Platform.Kind) -> CGSize {
                platform == .androidPhone ? CGSize(width: 1080, height: 2400) : platform.screenshotSize
            }
            func render(_ shot: FramedShot, on canvas: Canvas) throws {}
        }
        let fixture = try playFixture()
        fixture.project.frames = Tall()
        try fixture.writeCaptures()
        await #expect { try await push(fixture) } throws: { error in
            "\(error)".contains("the theme draws Android phone screenshots at 1080 × 2400, which Google Play does not take")
        }
        #expect(fixture.play.requests.isEmpty)
    }

    @Test func theAppStorePushTakesNoGooglePlayPlatform() async throws {
        let fixture = try playFixture()
        await #expect { try await Commands.pushScreenshots(fixture.session, platforms: "android", locales: "", options: apply) } throws: {
            "\($0)" == "Unknown App Store Connect platform android. This project has ios."
        }
    }
}

@Suite struct PlayStatusTests {
    @Test func statusShowsTracksListingsAndImagesAndWritesNothing() async throws {
        var live = FakeGooglePlay.State()
        live.tracks = [PlayTrack(track: "production", releases: [
            PlayTrack.Release(name: "1.0", versionCodes: ["10"], status: "inProgress", userFraction: 0.2),
        ]), PlayTrack(track: "internal", releases: [])]
        live.listings["en-US"] = PlayListing(language: "en-US", title: "Example", shortDescription: "Old.",
                                             fullDescription: "Every alert rings until you answer.")
        live.images["en-US"] = [.phoneScreenshots: [FakeGooglePlay.Image(id: "a", data: Data([1])), FakeGooglePlay.Image(id: "b", data: Data([2]))]]
        let fixture = try playFixture()
        fixture.play.reset(to: live)
        try await Commands.playStatus(fixture.session)
        let output = fixture.console.output
        #expect(output.contains("com.example.app, default language en-US"))
        #expect(output.contains("  production  1.0 (10) inProgress to 20%"))
        #expect(output.contains("  internal    no releases"))
        #expect(output.contains("  differ from the catalog: en-US (Google Play short description)"))
        #expect(output.contains("  missing: da-DK"))
        #expect(output.contains("  Android phone: 2 in en-US; none in da-DK"))
        #expect(fixture.play.live == live)
        #expect(fixture.play.openEdits == 0)
    }
}
