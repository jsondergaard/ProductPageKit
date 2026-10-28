import CryptoKit
import Foundation
import Testing
@testable import ProductPageKit
@testable import ProductPageKitRunner

/// `Archiver` archiving `Fixtures/SampleApp` with `xcodebuild`. Signed to run
/// locally, so it needs no account, and never uploaded.
@Suite(.serialized) struct ArchiveTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ArchiveTests-\(UUID().uuidString)")
    let number = BuildNumber(major: 7, minor: 3)

    var cache: Cache { Cache(bundleID: CaptureTests.project.bundleID, root: folder.appending(path: "cache")) }

    func archiver(_ afterArchive: [String]) throws -> Archiver {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = folder.appending(path: "AuthKey_KEY.p8")
        try P256.Signing.PrivateKey().pemRepresentation.write(to: key, atomically: true, encoding: .utf8)
        var project = CaptureTests.project
        project.builds = Builds(afterArchive: afterArchive)
        return try Archiver(project: project, root: CaptureTests.packageRoot,
                            cache: cache,
                            key: APIKey(file: key, id: "KEY", issuer: "issuer"),
                            archives: folder.appending(path: "Archives")) { _ in }
    }

    func url(_ platform: StorePlatform) -> URL {
        folder.appending(path: "Archives/2026-10-28/Sample \(platform.name) 7.3.xcarchive")
    }

    @Test func archivesNumberedAndRunsTheCommandsAfter() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appending(path: "after.txt")
        let archiver = try archiver(["printf %s \"$\(Builds.archiveVariable)\" > '\(marker.path)'"])

        let archives = try await archiver.archive([.macOS], number: number, date: Date(timeIntervalSince1970: 1_793_188_800))

        #expect(archives == [Archive(platform: .macOS, url: url(.macOS), version: "1.0", number: number)])
        #expect(FileManager.default.fileExists(atPath: url(.macOS).appending(path: "Products/Applications/SampleApp.app").path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == url(.macOS).path)
    }

    /// The Mac archive's command writes the marker only once the iOS archive
    /// has started, so it is written only when commands run while the next
    /// platform archives. The fixture has no iOS profile, so that archive
    /// fails and the run returns nothing.
    @Test func commandsRunWhileTheNextPlatformArchives() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appending(path: "after.txt")
        let nextStarted = cache.logs.appending(path: "ios-archive.log")
        let archiver = try archiver([
            """
            for i in {1..600}; do [ -f '\(nextStarted.path)' ] && break; sleep 0.1; done
            [ -f '\(nextStarted.path)' ] && printf %s "$\(Builds.archiveVariable)" > '\(marker.path)'
            """,
        ])

        await #expect(throws: ShellError.self) {
            try await archiver.archive([.macOS, .iOS], number: number, date: Date(timeIntervalSince1970: 1_793_188_800))
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == url(.macOS).path)
    }

    @Test func aFailedCommandReturnsNothingToUpload() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let archiver = try archiver(["exit 3"])
        await #expect(throws: ShellError.self) {
            try await archiver.archive([.macOS], number: number, date: Date(timeIntervalSince1970: 1_793_188_800))
        }
    }
}
