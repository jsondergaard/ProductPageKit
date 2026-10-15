import ArgumentParser
import Foundation
import Testing
@testable import ProductPageKit
@testable import ProductPageKitCore
import ProductPageKitASC

let apply = try! WriteOptions.parse(["--yes"])
let dryRun = try! WriteOptions.parse(["--dry-run"])

@Suite struct MetadataTests {
    @Test func pushWritesEveryFieldThenFindsNothingToChange() async throws {
        let fixture = try Fixture()
        fixture.fake.add("appInfoLocalizations", ["locale": "en-US", "name": "Old name", "subtitle": "Old"],
                         relationships: ["appInfo": ("appInfos", "info")])
        fixture.fake.add("appStoreVersionLocalizations", ["locale": "en-US", "keywords": "old"],
                         relationships: ["appStoreVersion": ("appStoreVersions", "ios")])

        try await Commands.pushMetadata(fixture.session, locales: "", platforms: "", options: apply)

        let info = fixture.fake.all("appInfoLocalizations")
        #expect(info.map { $0.attributes["locale"] as? String } == ["en-US", "da"])
        #expect(info.map { $0.attributes["name"] as? String } == ["Example", "Eksempel"])
        #expect(info.allSatisfy { $0.attributes["privacyPolicyUrl"] as? String == "https://example.com/privacy" })

        // Adding Danish to the app made App Store Connect add it to the
        // version, so the planned create collided and updated that instead.
        let versions = fixture.fake.all("appStoreVersionLocalizations")
        #expect(versions.count == 2)
        let danish = try #require(versions.first { $0.attributes["locale"] as? String == "da" })
        #expect(danish.attributes["keywords"] as? String == "push,personsøger")
        #expect(danish.attributes["whatsNew"] as? String == "Hurtigere.")
        #expect(danish.attributes["supportUrl"] as? String == "https://example.com/support")

        #expect(fixture.fake.resource("ios")?.attributes["copyright"] as? String == "2026 Example")
        let review = try #require(fixture.fake.all("appStoreReviewDetails").first)
        #expect(review.attributes["notes"] as? String == "Sign in with the demo account.")
        #expect(review.attributes["demoAccountRequired"] as? Bool == true)
        #expect(review.attributes["demoAccountName"] as? String == "review@example.com")
        #expect(review.attributes["contactFirstName"] as? String == "Ada")

        let output = fixture.console.output
        #expect(!output.contains("s3cret-code"))
        #expect(output.contains("demoAccountPassword: set (not shown)"))
        #expect(output.contains("update  App · en-US"))
        #expect(output.contains("name: Old name → Example"))
        #expect(output.contains("warning: macOS has no editable version"))
        #expect(output.contains("Applied 6 changes."), "\(output)")

        fixture.fake.clearWrites()
        let second = try fixture.again()
        try await Commands.pushMetadata(second.session, locales: "", platforms: "", options: apply)
        #expect(second.console.output.contains("Nothing to change."))
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func aDryRunPrintsThePlanAndWritesNothing() async throws {
        let fixture = try Fixture()
        try await Commands.pushMetadata(fixture.session, locales: "", platforms: "", options: dryRun)
        #expect(fixture.fake.writes.isEmpty)
        let output = fixture.console.output
        #expect(output.contains("create  App · en-US"))
        #expect(output.contains("create  iOS 1.2 · da"))
        #expect(output.contains("Dry run: 6 changes, nothing written."))
    }

    @Test func aTranslationNeedingReviewIsLeftAlone() async throws {
        let fixture = try Fixture()
        try fixture.updateCopy { $0.catalog.set("Eksempel Pro", for: "name", language: "da", state: .needsReview) }
        try await Commands.pushMetadata(fixture.session, locales: "da", platforms: "ios", options: apply)
        #expect(fixture.fake.all("appInfoLocalizations").isEmpty)
        #expect(fixture.console.output.contains("warning: da has no translated name, so da is not added to the app"))
    }

    @Test func flagsLimitTheLocalesAndPlatforms() async throws {
        let fixture = try Fixture()
        try await Commands.pushMetadata(fixture.session, locales: "da", platforms: "ios", options: apply)
        #expect(fixture.fake.all("appStoreVersionLocalizations").compactMap { $0.attributes["locale"] as? String } == ["da"])
        await #expect(throws: Stopped.self) {
            try await Commands.pushMetadata(fixture.session, locales: "fr", platforms: "", options: apply)
        }
    }

    @Test func aProblemInTheCopyStopsBeforeAnyRequest() async throws {
        let fixture = try Fixture()
        try fixture.updateCopy { $0.set(String(repeating: "x", count: 31), field: .name, locale: fixture.en) }
        await #expect(throws: ProblemsError.self) {
            try await Commands.pushMetadata(fixture.session, locales: "", platforms: "", options: apply)
        }
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func withoutATerminalItNeedsYes() async throws {
        let fixture = try Fixture()
        fixture.console = RecordingConsole(interactive: false)
        do {
            try await Commands.pushMetadata(fixture.session, locales: "", platforms: "", options: try .parse([]))
            Issue.record("expected it to stop")
        } catch let stopped as Stopped {
            #expect(stopped.description == "Pass --yes to apply without a terminal.")
        }
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func decliningChangesNothing() async throws {
        let fixture = try Fixture()
        fixture.console = RecordingConsole(answers: ["n"])
        await #expect(throws: Stopped.self) {
            try await Commands.pushMetadata(fixture.session, locales: "", platforms: "", options: try .parse([]))
        }
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func pullWritesTheLiveTextAndEveryReleaseIntoTheCatalog() async throws {
        let fixture = try Fixture()
        fixture.fake.add("appStoreVersions", id: "ios-old", ["platform": "IOS", "versionString": "1.1", "appStoreState": "READY_FOR_SALE"],
                         relationships: ["app": ("apps", "app")])
        fixture.fake.add("appStoreVersionLocalizations", ["locale": "en-US", "whatsNew": "First update."],
                         relationships: ["appStoreVersion": ("appStoreVersions", "ios-old")])
        try await Commands.pushMetadata(fixture.session, locales: "", platforms: "", options: apply)
        try FileManager.default.removeItem(at: StoreCopy.url(fixture.project, root: fixture.root))

        try await Commands.pullMetadata(fixture.session, platform: nil)

        let copy = try fixture.copy
        #expect(copy.value(.name, locale: fixture.da) == "Eksempel")
        #expect(copy.value(.keywords, locale: fixture.en) == "push,pager")
        #expect(copy.value(.whatsNew("1.2"), locale: fixture.da) == "Hurtigere.")
        #expect(copy.value(.whatsNew("1.1"), locale: fixture.en) == "First update.")
        #expect(copy.value(.reviewNotes, locale: fixture.en) == "Sign in with the demo account.")
        #expect(copy.releases == ["1.1", "1.2"])
        #expect(copy.catalog.strings["name"]?.comment == "App name, up to 30 characters.")

        let again = try fixture.again()
        try await Commands.pullMetadata(again.session, platform: "ios")
        #expect(again.console.output.contains("already holds what App Store Connect has"))
    }

    @Test func checkReportsReleasesAndFailsOnErrors() throws {
        let fixture = try Fixture()
        try Commands.checkMetadata(fixture.session)
        #expect(fixture.console.output.contains("AppStore.xcstrings is ready: What's New for 1.2."))
        try fixture.updateCopy { $0.set("No link", field: .description, locale: fixture.da) }
        #expect(throws: ProblemsError.self) { try Commands.checkMetadata(fixture.session) }
    }

    @Test func releaseNewAddsAnEmptyEntryOnce() throws {
        let fixture = try Fixture()
        try Commands.newRelease(fixture.session, version: "1.3")
        #expect(try fixture.copy.catalog.unit("whatsNew.1.3", language: "da")?.state == "new")
        #expect(throws: ReleaseExists.self) { try Commands.newRelease(fixture.session, version: "1.3") }
    }
}
