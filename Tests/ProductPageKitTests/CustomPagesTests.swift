import Foundation
import Testing
@testable import ProductPageKit
@testable import ProductPageKitCore

/// `pages push` against an in-memory App Store Connect: a page is found by
/// name or made, its copy, keywords and screenshots kept in step, and an
/// approved version replaced by a copy holding only the differences.
@Suite struct CustomPagesTests {
    /// The sample theme frames the captures; the page shows the list without
    /// a caption of its own, and home with one.
    func fixture() throws -> Fixture {
        let fixture = try Fixture(themes: .frames)
        fixture.project.customPages = [CustomPage("pager", name: "Pager", platforms: [.iPhone], shots: ["home", "list"],
                                                  storeCaptions: ["list"], keywords: ["pager", "personsøger", "beeper"])]
        fixture.fake.keywordPools = ["en-US": ["push", "pager"], "da": ["push"]]
        try fixture.writeCatalog()
        try fixture.updateCopy { copy in
            let page = fixture.project.customPages[0]
            copy.set("For people on call.", field: page.promotionalText, locale: fixture.en)
            copy.set("Til folk med vagt.", field: page.promotionalText, locale: fixture.da)
        }
        try fixture.writeCaptures()
        return fixture
    }

    func push(_ fixture: Fixture, options: WriteOptions = apply) async throws {
        try await Commands.pushPages(fixture.session, pages: "", platforms: "", locales: "", options: options)
    }

    func localization(_ fixture: Fixture, _ locale: String, version: String? = nil) throws -> FakeAppStoreConnect.Resource {
        let versions = fixture.fake.all("appCustomProductPageVersions")
        let versionID = try #require(version ?? versions.last?.id)
        return try #require(fixture.fake.all("appCustomProductPageLocalizations").first {
            $0.attributes["locale"] as? String == locale && $0.relationships["appCustomProductPageVersion"]?.id == versionID
        })
    }

    func shots(_ fixture: Fixture, in localization: FakeAppStoreConnect.Resource) throws -> [String?] {
        let set = try #require(fixture.fake.all("appScreenshotSets").first {
            $0.relationships["appCustomProductPageLocalization"]?.id == localization.id
        })
        #expect(set.attributes["screenshotDisplayType"] as? String == "APP_IPHONE_67")
        return fixture.fake.screenshots(inSet: set.id).map { $0.attributes["fileName"] as? String }
    }

    @Test func aMissingPageIsMadeShownAndFilled() async throws {
        let fixture = try fixture()
        try await push(fixture)

        let page = try #require(fixture.fake.all("appCustomProductPages").first)
        #expect(page.attributes["name"] as? String == "Pager")
        #expect(page.attributes["visible"] as? Bool == true)
        let english = try localization(fixture, "en-US")
        #expect(english.attributes["promotionalText"] as? String == "For people on call.")
        #expect(try shots(fixture, in: english) == ["01_home.png", "02_list.png"])
        // Only terms the locale's keywords hold and the live version offers.
        #expect(fixture.fake.keywords(assignedTo: english.id) == ["pager"])
        let danish = try localization(fixture, "da")
        #expect(danish.attributes["promotionalText"] as? String == "Til folk med vagt.")
        #expect(fixture.fake.keywords(assignedTo: danish.id).isEmpty)
        #expect(fixture.console.output.contains("warning: Pager page · da: personsøger is not among the live version's keywords yet"))
        #expect(!fixture.fake.writes.contains { $0.contains("Submission") })

        fixture.fake.clearWrites()
        let second = try fixture.again()
        second.project.customPages = fixture.project.customPages
        try await push(second)
        #expect(second.console.output.contains("Nothing to change."))
        #expect(fixture.fake.writes.isEmpty)
    }

    /// An approved version is frozen: the page gets a new one, which starts
    /// as its copy, and only what differs is written to it.
    @Test func anApprovedVersionIsReplacedByACopyWithTheDifferences() async throws {
        let fixture = try fixture()
        try await push(fixture)
        let first = try #require(fixture.fake.all("appCustomProductPageVersions").first)
        fixture.fake.change(first.id, ["state": "APPROVED"])
        try fixture.writeCapture(.iPhone, fixture.da, "list", shade: 250)
        try fixture.updateCopy { $0.set("Nyt for folk med vagt.", field: fixture.project.customPages[0].promotionalText, locale: fixture.da) }
        fixture.fake.clearWrites()

        try await push(fixture)

        let versions = fixture.fake.all("appCustomProductPageVersions")
        #expect(versions.count == 2)
        #expect(fixture.fake.resource(first.id)?.attributes["state"] as? String == "APPROVED")
        let danish = try localization(fixture, "da", version: versions[1].id)
        #expect(danish.attributes["promotionalText"] as? String == "Nyt for folk med vagt.")
        #expect(try shots(fixture, in: danish) == ["01_home.png", "02_list.png"])
        // One screenshot uploaded, its old one deleted, and English untouched.
        #expect(fixture.fake.writes.filter { $0 == "POST /v1/appScreenshots" }.count == 1)
        #expect(fixture.fake.writes.filter { $0.hasPrefix("DELETE /v1/appScreenshots/") }.count == 1)
        #expect(fixture.fake.writes.filter { $0.hasPrefix("PATCH /v1/appCustomProductPageLocalizations/") }.count == 1)
        #expect(fixture.console.output.contains("create  Pager page version"))
    }

    @Test func aVersionInReviewIsLeftAlone() async throws {
        let fixture = try fixture()
        try await push(fixture)
        let first = try #require(fixture.fake.all("appCustomProductPageVersions").first)
        fixture.fake.change(first.id, ["state": "WAITING_FOR_REVIEW"])
        try fixture.writeCapture(.iPhone, fixture.da, "list", shade: 250)
        fixture.fake.clearWrites()
        try await push(fixture)
        #expect(fixture.fake.writes.isEmpty)
        #expect(fixture.console.output.contains("warning: Pager page's version 1 is WAITING_FOR_REVIEW, so it is left as it is"))
    }

    @Test func aDryRunWritesNothing() async throws {
        let fixture = try fixture()
        try await push(fixture, options: dryRun)
        #expect(fixture.fake.writes.isEmpty)
        #expect(fixture.console.output.contains("create  Pager page"))
        #expect(fixture.console.output.contains("upload  Pager page · da · iPhone 6.9\""))
    }
}
