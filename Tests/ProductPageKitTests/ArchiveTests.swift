import CryptoKit
import Foundation
import Testing
@testable import ProductPageKit
@testable import ProductPageKitRunner

/// `Archiver` archiving `Fixtures/SampleApp` for this Mac with `xcodebuild`.
/// Signed to run locally, so it needs no account, and never uploaded.
@Suite struct ArchiveTests {
    @Test func archivesNumberedAndRunsTheCommandsAfter() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = folder.appending(path: "AuthKey_KEY.p8")
        try P256.Signing.PrivateKey().pemRepresentation.write(to: key, atomically: true, encoding: .utf8)
        var project = CaptureTests.project
        let marker = folder.appending(path: "after.txt")
        project.builds = Builds(platforms: [.macOS], afterArchive: ["printf %s \"$\(Builds.archiveVariable)\" > '\(marker.path)'"])

        let archiver = try Archiver(project: project, root: CaptureTests.packageRoot,
                                    cache: Cache(bundleID: project.bundleID, root: folder.appending(path: "cache")),
                                    key: APIKey(file: key, id: "KEY", issuer: "issuer"),
                                    archives: folder.appending(path: "Archives")) { _ in }
        let number = try #require(BuildNumber("7.3"))
        let archives = try await archiver.archive([.macOS], number: number, date: Date(timeIntervalSince1970: 1_793_188_800))

        let url = folder.appending(path: "Archives/2026-10-28/Sample macOS 7.3.xcarchive")
        #expect(archives == [Archive(platform: .macOS, url: url, version: "1.0", number: number)])
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "Products/Applications/SampleApp.app").path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == url.path)
    }
}
