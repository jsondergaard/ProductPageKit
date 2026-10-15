import CryptoKit
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ProductPageKitASC
import ProductPageKitCore

/// Answers each request with the next scripted response and records it.
final class ScriptedTransport: ClientTransport, @unchecked Sendable {
    struct Sent {
        let request: HTTPRequest
        let body: Data
        let baseURL: URL
    }

    private let lock = NSLock()
    private var responses: [(status: Int, body: String)]
    private(set) var sent: [Sent] = []

    init(_ responses: [(status: Int, body: String)]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { data = try await Data(collecting: body, upTo: .max) }
        let response = lock.withLock {
            sent.append(Sent(request: request, body: data, baseURL: baseURL))
            return responses.removeFirst()
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return (HTTPResponse(status: .init(code: response.status), headerFields: headers), HTTPBody(response.body))
    }
}

func credentials() -> Credentials {
    Credentials(issuerID: "issuer", keyID: "KEY123", privateKey: P256.Signing.PrivateKey())
}

@Suite struct TokenTests {
    @Test func signsAnES256TokenAppStoreConnectAccepts() throws {
        let key = credentials()
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try TokenSigner.sign(credentials: key, issuedAt: issued)
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        func decode(_ part: String) -> Data {
            var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            return Data(base64Encoded: base64)!
        }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as! [String: Any]
        let payload = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "KEY123")
        #expect(payload["iss"] as? String == "issuer")
        #expect(payload["aud"] as? String == "appstoreconnect-v1")
        #expect(payload["iat"] as? Int == 1_800_000_000)
        #expect(payload["exp"] as? Int == 1_800_000_900)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.privateKey.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func reusesATokenUntilAMinuteBeforeItExpires() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let signer = TokenSigner(credentials: credentials(), now: { clock.now })
        let first = try await signer.token()
        clock.now += 14 * 60 - 1
        #expect(try await signer.token() == first)
        clock.now += 2
        #expect(try await signer.token() != first)
    }

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
}

@Suite struct ClientTests {
    let appsPage = """
        {"data": [{"type": "apps", "id": "1", "attributes": {"name": "Example"}}], "links": {"self": "x"}}
        """

    @Test func signsEveryRequest() async throws {
        let transport = ScriptedTransport([(200, appsPage)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        let app = try await asc.app(bundleID: "com.example.app")
        #expect(app.id == "1")
        #expect(app.name == "Example")
        #expect(transport.sent[0].request.headerFields[.authorization]?.hasPrefix("Bearer ") == true)
        #expect(transport.sent[0].request.path?.contains("filter%5BbundleId%5D=com.example.app") == true)
    }

    @Test func anErrorResponseCarriesAppStoreConnectsExplanation() async throws {
        let transport = ScriptedTransport([(409, """
            {"errors": [{"status": "409", "code": "ENTITY_ERROR.DUPLICATE", "title": "Duplicate", "detail": "Locale exists."}]}
            """)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        do {
            try await asc.createVersionLocalization(versionID: "v1", locale: "en-US", text: VersionText())
            Issue.record("expected a conflict")
        } catch let error as ASCError {
            #expect(error.isDuplicate)
            #expect(error.status == 409)
            #expect(error.description == "POST /v1/appStoreVersionLocalizations -> 409: Duplicate: Locale exists.")
        }
    }

    @Test func anUnknownAppIsReported() async throws {
        let transport = ScriptedTransport([(200, #"{"data": [], "links": {"self": "x"}}"#)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        await #expect(throws: AppNotFound.self) { try await asc.app(bundleID: "com.missing") }
    }

    @Test func followsEveryPage() async throws {
        func page(_ id: String, next: String?) -> String {
            let links = next.map { #""self": "x", "next": "\#($0)""# } ?? #""self": "x""#
            return #"{"data": [{"type": "territories", "id": "\#(id)"}], "links": {\#(links)}}"#
        }
        let transport = ScriptedTransport([
            (200, page("USA", next: "https://api.appstoreconnect.apple.com/v1/territories?cursor=Mg&limit=200")),
            (200, page("DNK", next: nil)),
        ])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        #expect(try await asc.territories() == ["USA", "DNK"])
        #expect(transport.sent[1].request.path?.contains("cursor=Mg") == true)
        #expect(transport.sent[0].request.path?.contains("cursor") == false)
    }

    /// App Store Connect writes dates with fractional seconds and without.
    @Test func readsDatesWithAndWithoutFractionalSeconds() async throws {
        func placement(_ id: String, created: String) -> String {
            #"{"type": "appAssetLibraryPlacements", "id": "\#(id)", "attributes": {"placementType": "PRODUCT_PAGE_HEADER", "createdDate": "\#(created)"}}"#
        }
        let transport = ScriptedTransport([(200, #"{"data": ["#
            + placement("a", created: "2026-09-30T17:07:20.123-07:00") + ", "
            + placement("b", created: "2026-09-30T17:07:20Z") + #"], "links": {"self": "x"}}"#)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        #expect(try await asc.placements(localizationID: "loc", type: "PRODUCT_PAGE_HEADER").map(\.id) == ["a", "b"])
        #expect(try AppStoreConnectDates().decode("2026-09-30T17:07:20.123-07:00") == AppStoreConnectDates().decode("2026-10-01T00:07:20.123Z"))
    }

    @Test func anUpdateSendsOnlyWhatChanged() async throws {
        let transport = ScriptedTransport([(200, #"{"data": {"type": "appStoreVersionLocalizations", "id": "l1"}, "links": {"self": "x"}}"#)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        var live = VersionText()
        live.keywords = "push"
        live.description = "Same"
        var wanted = live
        wanted.keywords = "push,pager"
        try await asc.updateVersionLocalization(id: "l1", wanted.changes(from: live))
        let body = try JSONSerialization.jsonObject(with: transport.sent[0].body) as! [String: [String: Any]]
        #expect(body["data"]!["attributes"] as? [String: String] == ["keywords": "push,pager"])
    }

    @Test func uploadsAScreenshotInTheAskedPartsAndCommitsItsChecksum() async throws {
        let data = Data((0..<10).map { UInt8($0) })
        let transport = ScriptedTransport([
            (201, """
                {"data": {"type": "appScreenshots", "id": "s1", "attributes": {"uploadOperations": [
                  {"method": "PUT", "url": "https://upload.example/part?n=1", "offset": 0, "length": 6,
                   "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
                  {"method": "PUT", "url": "https://upload.example/part?n=2", "offset": 6, "length": 4, "requestHeaders": []}
                ]}}, "links": {"self": "x"}}
                """),
            (200, ""),
            (200, ""),
            (200, #"{"data": {"type": "appScreenshots", "id": "s1"}, "links": {"self": "x"}}"#),
        ])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        #expect(try await asc.uploadScreenshot(setID: "set1", fileName: "01.png", data: data) == "s1")

        #expect(transport.sent[1].baseURL.absoluteString == "https://upload.example")
        #expect(transport.sent[1].request.path == "/part?n=1")
        #expect(transport.sent[1].request.headerFields[.contentType] == "image/png")
        #expect(transport.sent[1].body == data.prefix(6))
        #expect(transport.sent[2].body == data.suffix(4))
        let commit = try JSONSerialization.jsonObject(with: transport.sent[3].body) as! [String: [String: Any]]
        let attributes = commit["data"]!["attributes"] as! [String: Any]
        #expect(attributes["uploaded"] as? Bool == true)
        #expect(attributes["sourceFileChecksum"] as? String == AppStoreConnect.md5(data))
    }

    @Test func aRejectedPartStopsTheUpload() async throws {
        let transport = ScriptedTransport([
            (201, """
                {"data": {"type": "appScreenshots", "id": "s1", "attributes": {"uploadOperations": [
                  {"method": "PUT", "url": "https://upload.example/part", "offset": 0, "length": 1}
                ]}}, "links": {"self": "x"}}
                """),
            (500, ""),
        ])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        await #expect(throws: UploadError.self) {
            try await asc.uploadScreenshot(setID: "set1", fileName: "01.png", data: Data([1]))
        }
    }

    @Test func aMissingToOneRelationshipIsNil() async throws {
        let transport = ScriptedTransport([(200, #"{"data": null, "links": {"self": "x"}}"#)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        #expect(try await asc.reviewDetail(versionID: "v1") == nil)
    }

    @Test func md5MatchesTheKnownDigest() {
        #expect(AppStoreConnect.md5(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
    }
}
