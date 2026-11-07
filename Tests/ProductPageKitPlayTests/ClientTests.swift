import Foundation
import HTTPTypes
import ProductPageKitCore
import ProductPageKitHTTP
@testable import ProductPageKitPlay
import ProductPageKitTestSupport
import Testing

@Suite struct PlayCredentialsTests {
    @Test func aServiceAccountKeyIsReadFromItsJSONOrItsFile() throws {
        let json = String(decoding: FakeGooglePlay.serviceAccountJSON, as: UTF8.self)
        let inline = try PlayCredentials(environment: Environment(values: ["PLAY_KEY_JSON": json]))
        #expect(inline.clientEmail == FakeGooglePlay.clientEmail)
        #expect(inline.tokenURI.absoluteString == "https://oauth2.example/token")

        let file = FileManager.default.temporaryDirectory.appending(path: "play-key-\(UUID().uuidString).json")
        try FakeGooglePlay.serviceAccountJSON.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try PlayCredentials(environment: Environment(values: ["PLAY_KEY_PATH": file.path])).clientEmail == FakeGooglePlay.clientEmail)
    }

    @Test func aMissingOrBrokenKeySaysWhich() {
        #expect { try PlayCredentials(environment: Environment(values: [:])) } throws: {
            "\($0)".hasPrefix("Missing PLAY_KEY_PATH")
        }
        #expect { try PlayCredentials(environment: Environment(values: ["PLAY_KEY_PATH": "/nowhere/key.json"])) } throws: {
            "\($0)" == "PLAY_KEY_PATH does not exist: /nowhere/key.json"
        }
        #expect { try PlayCredentials(json: Data(#"{"type": "service_account", "client_email": "a@b", "private_key": "x"}"#.utf8), source: "k.json") }
            throws: { "\($0)" == "k.json is not a service account's JSON key with an RSA private key." }
    }

    /// The fake grants a token only to an assertion this key signed.
    @Test func theAssertionIsSignedWithTheKey() async throws {
        let fake = FakeGooglePlay()
        let api = GooglePlayAPI(credentials: FakeGooglePlay.credentials, transport: fake)
        let edit = try await api.edit(packageName: FakeGooglePlay.packageName)
        _ = try await edit.listings()
        // One token for both requests.
        #expect(fake.requests == ["POST /androidpublisher/v3/applications/com.example.app/edits",
                                  "GET /androidpublisher/v3/applications/com.example.app/edits/edit-2/listings"])
    }
}

@Suite struct PlayEditTests {
    func api(_ fake: FakeGooglePlay, retry: Retry = Retry()) -> GooglePlayAPI {
        GooglePlayAPI(credentials: FakeGooglePlay.credentials, transport: fake, retry: retry)
    }

    @Test func aCommittedEditReplacesTheLiveListing() async throws {
        let fake = FakeGooglePlay()
        let edit = try await api(fake).edit(packageName: FakeGooglePlay.packageName)
        try await edit.putListing(PlayListing(language: "da-DK", title: "Eksempel", shortDescription: "Kort.", fullDescription: "Lang."))
        try await edit.patchListing(language: "da-DK", PlayListing.Text(shortDescription: "Kortere."))
        let image = try await edit.upload(Data([1, 2, 3]), contentType: "image/png", language: "da-DK", type: .phoneScreenshots)
        #expect(try await edit.images(language: "da-DK", type: .phoneScreenshots) == [image])
        #expect(image.sha256 == "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
        #expect(fake.live.listings.isEmpty)

        try await edit.commit(sendForReview: true)
        #expect(fake.live.listings["da-DK"] == PlayListing(language: "da-DK", title: "Eksempel", shortDescription: "Kortere.",
                                                            fullDescription: "Lang."))
        #expect(fake.live.images["da-DK"]?[.phoneScreenshots]?.map(\.data) == [Data([1, 2, 3])])
        #expect(fake.commitQueries == [""])
        #expect(fake.openEdits == 0)
    }

    @Test func aDeletedEditLeavesTheListingAlone() async throws {
        var live = FakeGooglePlay.State()
        live.listings["en-US"] = PlayListing(language: "en-US", title: "Example", shortDescription: "Short.", fullDescription: "Long.")
        let fake = FakeGooglePlay(live)
        let edit = try await api(fake).edit(packageName: FakeGooglePlay.packageName)
        try await edit.patchListing(language: "en-US", PlayListing.Text(title: "Changed"))
        try await edit.delete()
        #expect(fake.live == live)
        #expect(fake.openEdits == 0)
    }

    @Test func managedPublishingCommitsWithoutSendingForReview() async throws {
        let fake = FakeGooglePlay()
        let edit = try await api(fake).edit(packageName: FakeGooglePlay.packageName)
        try await edit.commit(sendForReview: false)
        #expect(fake.commitQueries == ["changesNotSentForReview=true"])
    }

    @Test func anErrorCarriesGooglesMessage() async throws {
        let edit = try await api(FakeGooglePlay()).edit(packageName: FakeGooglePlay.packageName)
        await #expect { try await edit.patchListing(language: "fi-FI", PlayListing.Text(title: "Esimerkki")) } throws: { error in
            (error as? PlayError)?.status == 404 && (error as? PlayError)?.message == "no listing for fi-FI"
        }
    }

    /// A busy read is sent again; an upload, which may have gone through,
    /// is not.
    @Test func aBusyReadIsRetriedAndAnUploadIsNot() async throws {
        let fake = FakeGooglePlay()
        let waits = Waits()
        let edit = try await api(fake, retry: waits.retry).edit(packageName: FakeGooglePlay.packageName)
        fake.fail("GET", "/listings")
        #expect(try await edit.listings().isEmpty)
        #expect(waits.all == [.seconds(2)])
        fake.fail("POST", "/phoneScreenshots")
        await #expect(throws: PlayError.self) {
            try await edit.upload(Data([1]), contentType: "image/png", language: "en-US", type: .phoneScreenshots)
        }
        #expect(waits.all == [.seconds(2)])
    }
}

/// The waits a retry slept, without sleeping.
final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var all: [Duration] { lock.withLock { recorded } }

    var retry: Retry {
        Retry(attempts: 3) { [self] wait in lock.withLock { recorded.append(wait) } }
    }
}
