import Foundation
import Testing
@testable import ProductPageKitASC
import ProductPageKitCore

@Suite struct BuildsTests {
    @Test func readsEveryPageWithEachBuildsVersionAndPlatform() async throws {
        let first = """
            {"data": [
              {"type": "builds", "id": "b2", "attributes": {"version": "88.1", "uploadedDate": "2026-10-28T12:00:00Z",
                "processingState": "PROCESSING", "buildAudienceType": "INTERNAL_ONLY", "expired": false},
               "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "v1"}}}}
            ],
            "included": [{"type": "preReleaseVersions", "id": "v1", "attributes": {"version": "1.10.0", "platform": "TV_OS"}}],
            "links": {"self": "x", "next": "https://api.appstoreconnect.apple.com/v1/builds?cursor=MQ&limit=200"}}
            """
        let second = """
            {"data": [{"type": "builds", "id": "b1", "attributes": {"version": "88", "processingState": "VALID",
              "buildAudienceType": "APP_STORE_ELIGIBLE", "expired": true}}],
             "links": {"self": "x"}}
            """
        let transport = ScriptedTransport([(200, first), (200, second)])
        let builds = try await AppStoreConnect(credentials: credentials(), transport: transport).builds(appID: "app")
        #expect(builds == [
            Build(id: "b2", number: "88.1", version: "1.10.0", platform: .tvOS,
                  uploaded: Date(timeIntervalSince1970: 1_793_188_800), processingState: "PROCESSING",
                  audience: "INTERNAL_ONLY", expired: false),
            Build(id: "b1", number: "88", version: nil, platform: nil, uploaded: nil, processingState: "VALID",
                  audience: "APP_STORE_ELIGIBLE", expired: true),
        ])
        let query = try #require(transport.sent[0].request.path)
        for part in ["filter%5Bapp%5D=app", "sort=-uploadedDate", "include=preReleaseVersion", "limit=200"] {
            #expect(query.contains(part), "\(part) in \(query)")
        }
        #expect(transport.sent[1].request.path?.contains("cursor=MQ") == true)
    }

    @Test func keepsTheKeyFileItWasReadFrom() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitASCTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "AuthKey_KEY.p8")
        try credentials().privateKey.pemRepresentation.write(to: file, atomically: true, encoding: .utf8)
        let read = try Credentials(environment: Environment(values: [
            "ASC_ISSUER_ID": "issuer", "ASC_KEY_ID": "KEY", "ASC_KEY_PATH": file.path,
        ]))
        #expect(read.keyFile == file)
        #expect(credentials().keyFile == nil)
    }
}
