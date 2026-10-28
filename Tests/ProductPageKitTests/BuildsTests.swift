import CryptoKit
import Foundation
import Testing
@testable import ProductPageKit
import ProductPageKitRunner

/// `builds list` and `builds upload` against the fake App Store Connect.
/// The archiving itself is ArchiveTests'.
@Suite struct BuildsCommandTests {
    /// A fixture whose app has builds 88 (iOS) and 88.1 (tvOS, expired),
    /// newest first, and a key file the environment names.
    func fixture(builds: Builds? = Builds(platforms: [.iOS, .tvOS], numbering: .minor)) throws -> Fixture {
        let fake = FakeAppStoreConnect.seeded()
        let ios = fake.add("preReleaseVersions", ["version": "1.2", "platform": "IOS"])
        let tvos = fake.add("preReleaseVersions", ["version": "1.2", "platform": "TV_OS"])
        fake.add("builds", ["version": "88.1", "processingState": "VALID", "buildAudienceType": "INTERNAL_ONLY", "expired": true],
                 relationships: ["app": ("apps", "app"), "preReleaseVersion": ("preReleaseVersions", tvos)])
        fake.add("builds", ["version": "88", "processingState": "PROCESSING", "buildAudienceType": "APP_STORE_ELIGIBLE", "expired": false],
                 relationships: ["app": ("apps", "app"), "preReleaseVersion": ("preReleaseVersions", ios)])
        let fixture = try Fixture(fake: fake)
        fixture.project.xcode = .project("Example.xcodeproj", scheme: "Example")
        fixture.project.builds = builds
        let key = "AuthKey_KEY.p8"
        try fixture.write(P256.Signing.PrivateKey().pemRepresentation, to: key)
        fixture.environment["ASC_ISSUER_ID"] = "issuer"
        fixture.environment["ASC_KEY_ID"] = "KEY"
        fixture.environment["ASC_KEY_PATH"] = fixture.root.appending(path: key).path
        return fixture
    }

    @Test func listsTheBuildsOnThePlatformsItArchives() async throws {
        let fixture = try fixture()
        try await Commands.listBuilds(fixture.session, platforms: "", limit: 20)
        let lines = fixture.console.output.split(separator: "\n").map(String.init)
        try #require(lines.count == 2, "\(fixture.console.output)")
        #expect(lines[0].hasPrefix("1.2 (88.1)  tvOS       expired      internal only"))
        #expect(lines[1].hasPrefix("1.2 (88)    iOS        processing   App Store"))
    }

    @Test func listsOnlyTheNamedPlatformAndSaysWhatTheLimitLeftOut() async throws {
        let fixture = try fixture()
        try await Commands.listBuilds(fixture.session, platforms: "ios", limit: 20)
        #expect(!fixture.console.output.contains("tvOS"))
        fixture.console = RecordingConsole()
        try await Commands.listBuilds(fixture.session, platforms: "", limit: 1)
        #expect(fixture.console.output.hasSuffix("1 older build not shown; --limit shows more."))
    }

    @Test func aDryRunPlansTheNextNumberForEachPlatformAndArchivesNothing() async throws {
        let fixture = try fixture()
        let archives = fixture.root.appending(path: "Archives")
        try await Commands.uploadBuilds(fixture.session, platforms: "", options: try WriteOptions.parse(["--dry-run"]),
                                        archives: archives)
        let output = fixture.console.output
        #expect(output.contains("upload  Example iOS build 88.2"))
        #expect(output.contains("upload  Example tvOS build 88.2"))
        #expect(output.contains("for internal testers only"))
        #expect(output.contains("Dry run: 2 changes, nothing written."))
        #expect(!FileManager.default.fileExists(atPath: archives.path))
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func decliningArchivesNothing() async throws {
        let fixture = try fixture(builds: Builds(platforms: [.iOS], audience: .everyone))
        fixture.console = RecordingConsole(answers: ["n"])
        let archives = fixture.root.appending(path: "Archives")
        await #expect(throws: Stopped.self) {
            try await Commands.uploadBuilds(fixture.session, platforms: "", options: try WriteOptions.parse([]), archives: archives)
        }
        #expect(fixture.console.output.contains("upload  Example iOS build 89"))
        #expect(fixture.console.output.contains("for every tester and App Store review"))
        #expect(!FileManager.default.fileExists(atPath: archives.path))
    }

    @Test func aProjectWithoutBuildsHasNoneToUpload() async throws {
        let fixture = try fixture(builds: nil)
        await #expect(throws: ArchiveError.self) {
            try await Commands.uploadBuilds(fixture.session, platforms: "", options: try WriteOptions.parse(["--dry-run"]))
        }
    }

    @Test func anUnknownPlatformIsNamed() async throws {
        let fixture = try fixture()
        await #expect { try await Commands.listBuilds(fixture.session, platforms: "macos", limit: 20) } throws: { error in
            "\(error)" == "Unknown platform macos. This project has ios, tvos."
        }
    }
}
