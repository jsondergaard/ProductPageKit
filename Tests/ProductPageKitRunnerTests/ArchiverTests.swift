import CryptoKit
import Foundation
@testable import ProductPageKitCore
import Testing
@testable import ProductPageKitRunner

@Suite struct ArchiverTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ArchiverTests-\(UUID().uuidString)")

    func archiver(audience: TestFlightAudience = .internalOnly) throws -> Archiver {
        let project = Project(
            name: "Example", bundleID: "com.example.app", xcode: .project("App.xcodeproj", scheme: "App"),
            locales: [StoreLocale("en", store: "en-US")], platforms: [.iPhone()],
            metadata: Metadata(urls: URLs(marketing: "https://example.com", support: "https://example.com/support",
                                          privacy: "https://example.com/privacy"), copyright: "2026 Example"),
            builds: Builds(audience: audience)
        )
        return try Archiver(project: project, root: folder, cache: Cache(bundleID: project.bundleID, root: folder),
                            key: APIKey(file: folder.appending(path: "key.p8"), id: "KEY", issuer: "issuer"),
                            archives: folder.appending(path: "Archives")) { _ in }
    }

    /// An `.xcarchive` holding only what the Organizer and the check read.
    func archive(bundleID: String = "com.example.app", number: String? = "88.1") throws -> URL {
        let url = folder.appending(path: "Example.xcarchive")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var app: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.10.0"]
        app["CFBundleVersion"] = number
        try PropertyListSerialization.data(fromPropertyList: ["ApplicationProperties": app], format: .xml, options: 0)
            .write(to: url.appending(path: "Info.plist"))
        return url
    }

    @Test func readsTheArchivesVersion() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try archive()
        let read = try archiver().read(url, platform: .iOS, number: #require(BuildNumber("88.1")))
        #expect(read == Archive(platform: .iOS, url: url, version: "1.10.0", number: try #require(BuildNumber("88.1"))))
    }

    @Test func anArchiveThatIgnoredTheNumberIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try archive(number: "1")
        #expect {
            try archiver().read(url, platform: .tvOS, number: #require(BuildNumber("88.1")))
        } throws: { error in
            "\(error)".contains("The tvOS archive is build 1, not 88.1") && "\(error)".contains("$(CURRENT_PROJECT_VERSION)")
        }
    }

    @Test func anArchiveOfAnotherAppIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try archive(bundleID: "com.example.widget")
        #expect(throws: ArchiveError.self) { try archiver().read(url, platform: .iOS, number: #require(BuildNumber("88.1"))) }
    }

    @Test func uploadsKeepTheNumberAndTheAudience() {
        let internalOnly = Archiver.exportOptions(.internalOnly)
        #expect(internalOnly["method"] as? String == "app-store-connect")
        #expect(internalOnly["destination"] as? String == "upload")
        #expect(internalOnly["manageAppVersionAndBuildNumber"] as? Bool == false)
        #expect(internalOnly["testFlightInternalTestingOnly"] as? Bool == true)
        #expect(Archiver.exportOptions(.everyone)["testFlightInternalTestingOnly"] as? Bool == false)
    }

    @Test func needsBuildsAndAnXcodeProject() throws {
        var project = try archiver().project
        project.builds = nil
        #expect(throws: ArchiveError.self) {
            try Archiver(project: project, root: folder, cache: Cache(bundleID: "x", root: folder),
                         key: APIKey(file: folder, id: "", issuer: ""), log: { _ in })
        }
    }
}
